#!/usr/bin/env bash
set -euo pipefail

CPU_WARN=90
MEM_WARN=85
DISK_WARN=80
CPU_CRIT=95
MEM_CRIT=95
DISK_CRIT=95
LOG_FILE="health_log.txt"
MAX_LOG_BYTES=1048576
MAX_LOG_BACKUPS=3
JSON_OUTPUT=false

usage() {
  cat <<'EOF'
Usage: system_health.sh [OPTIONS]

Collect host CPU, memory, mounted disk usage, load average, and top 5 memory
processes, append a timestamped entry to health_log.txt, and return a monitoring
exit code (0 = healthy, 1 = warning, 2 = critical, 3 = usage/runtime error).

Options:
  --cpu N            CPU warning threshold % (default: 90)
  --mem N            Memory warning threshold % (default: 85)
  --disk N           Disk warning threshold % (default: 80)
  --cpu-crit N       CPU critical threshold % (default: 95)
  --mem-crit N       Memory critical threshold % (default: 95)
  --disk-crit N      Disk critical threshold % (default: 95)
  --log-file PATH    Log file path (default: health_log.txt)
  --max-log-bytes N  Rotate log once size reaches N bytes (default: 1048576)
  --json             Print JSON output to stdout (warnings go to stderr)
  -h, --help         Show this help message and exit

Environment:
  HEALTH_WEBHOOK_URL  Optional Slack or Discord webhook URL alerted on exit 1/2
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 3
}

is_pct() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 0 && "$1" <= 100 ))
}

is_pos_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

require_arg() {
  (( $# >= 2 )) || die "missing value for $1"
}

gt_num() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

json_escape() {
  awk -v s="$1" 'BEGIN {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, "\\t", s)
    gsub(/\r/, "", s)
    gsub(/\n/, "\\n", s)
    printf "\"%s\"", s
  }'
}

read_cpu_stat() {
  awk '/^cpu / {
    idle = $5 + $6
    total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
    print total, idle
    exit
  }' /proc/stat
}

rotate_log() {
  local file="$1"
  local max_bytes="$2"
  local max_backups="$3"
  [[ -f "$file" ]] || return 0

  local size
  size=$(wc -c < "$file")
  if (( size < max_bytes )); then
    return 0
  fi

  local i prev
  for (( i = max_backups; i >= 1; i-- )); do
    if (( i == 1 )); then
      prev="$file"
    else
      prev="${file}.$((i - 1))"
    fi
    if [[ -f "$prev" ]]; then
      mv -f "$prev" "${file}.${i}"
    fi
  done
}

collect_disks() {
  if df -Pk -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs >/dev/null 2>&1; then
    df -Pk -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs | awk 'NR > 1 && NF >= 6 {
      pct = $5; gsub(/%/, "", pct)
      mount = $6
      for (i = 7; i <= NF; i++) mount = mount " " $i
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, pct, mount
    }'
  else
    df -Pk | awk 'NR > 1 && $1 ~ /^\// && NF >= 6 {
      pct = $5; gsub(/%/, "", pct)
      mount = $6
      for (i = 7; i <= NF; i++) mount = mount " " $i
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, pct, mount
    }'
  fi
}

collect_top_procs() {
  ps -eo pid=,%mem=,%cpu=,comm= --sort=-%mem | awk 'NR <= 5 && NF >= 4 {
    pid = $1; mem = $2; cpu = $3
    cmd = $4
    for (i = 5; i <= NF; i++) cmd = cmd " " $i
    printf "%s\t%s\t%s\t%s\n", pid, mem, cpu, cmd
  }'
}

cpu_crit_set=false
mem_crit_set=false
disk_crit_set=false

while (( $# > 0 )); do
  case "$1" in
    --cpu)
      require_arg "$@"
      is_pct "$2" || die "--cpu must be an integer 0..100"
      CPU_WARN="$2"
      shift 2
      ;;
    --mem)
      require_arg "$@"
      is_pct "$2" || die "--mem must be an integer 0..100"
      MEM_WARN="$2"
      shift 2
      ;;
    --disk)
      require_arg "$@"
      is_pct "$2" || die "--disk must be an integer 0..100"
      DISK_WARN="$2"
      shift 2
      ;;
    --cpu-crit)
      require_arg "$@"
      is_pct "$2" || die "--cpu-crit must be an integer 0..100"
      CPU_CRIT="$2"
      cpu_crit_set=true
      shift 2
      ;;
    --mem-crit)
      require_arg "$@"
      is_pct "$2" || die "--mem-crit must be an integer 0..100"
      MEM_CRIT="$2"
      mem_crit_set=true
      shift 2
      ;;
    --disk-crit)
      require_arg "$@"
      is_pct "$2" || die "--disk-crit must be an integer 0..100"
      DISK_CRIT="$2"
      disk_crit_set=true
      shift 2
      ;;
    --log-file)
      require_arg "$@"
      LOG_FILE="$2"
      shift 2
      ;;
    --max-log-bytes)
      require_arg "$@"
      is_pos_int "$2" || die "--max-log-bytes must be a positive integer"
      MAX_LOG_BYTES="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

# Keep warning reachable if user only raised a warning threshold above default crit.
if ! "$cpu_crit_set" && (( CPU_WARN >= CPU_CRIT )); then CPU_CRIT=100; fi
if ! "$mem_crit_set" && (( MEM_WARN >= MEM_CRIT )); then MEM_CRIT=100; fi
if ! "$disk_crit_set" && (( DISK_WARN >= DISK_CRIT )); then DISK_CRIT=100; fi

for proc_file in /proc/stat /proc/meminfo /proc/loadavg; do
  [[ -r "$proc_file" ]] || die "cannot read $proc_file (Linux /proc required)"
done

timestamp=$(date -Iseconds)
host_name=$(hostname)

read -r t1 i1 < <(read_cpu_stat)
sleep 0.5
read -r t2 i2 < <(read_cpu_stat)
cpu_pct=$(awk -v t1="$t1" -v i1="$i1" -v t2="$t2" -v i2="$i2" 'BEGIN {
  dt = t2 - t1
  di = i2 - i1
  if (dt <= 0) { printf "0.0"; exit }
  printf "%.1f", ((dt - di) / dt) * 100
}')

read -r mem_used_mb mem_total_mb mem_pct < <(awk '
  /^MemTotal:/     { total = $2 }
  /^MemAvailable:/ { avail = $2 }
  /^MemFree:/      { mfree = $2 }
  /^Buffers:/      { buf = $2 }
  /^Cached:/       { cached = $2 }
  END {
    if (avail == "" && mfree != "") avail = mfree + buf + cached
    used = total - avail
    printf "%.0f %.0f %.1f\n", used / 1024, total / 1024, (total > 0 ? (used / total) * 100 : 0)
  }
' /proc/meminfo)

read -r load1 load5 load15 _ < /proc/loadavg

mapfile -t disk_rows < <(collect_disks)
mapfile -t proc_rows < <(collect_top_procs)

status="healthy"
exit_code=0
declare -a alerts=()

record_alert() {
  local severity="$1"
  local msg="$2"
  if [[ "$severity" == "critical" ]]; then
    alerts+=("[CRITICAL] $msg")
    exit_code=2
    status="critical"
  else
    alerts+=("[WARNING] $msg")
    if (( exit_code < 1 )); then
      exit_code=1
      status="warning"
    fi
  fi
}

if gt_num "$cpu_pct" "$CPU_CRIT"; then
  record_alert critical "CPU usage ${cpu_pct}% exceeds critical threshold ${CPU_CRIT}%"
elif gt_num "$cpu_pct" "$CPU_WARN"; then
  record_alert warning "CPU usage ${cpu_pct}% exceeds threshold ${CPU_WARN}%"
fi

if gt_num "$mem_pct" "$MEM_CRIT"; then
  record_alert critical "Memory usage ${mem_pct}% (${mem_used_mb}/${mem_total_mb} MiB) exceeds critical threshold ${MEM_CRIT}%"
elif gt_num "$mem_pct" "$MEM_WARN"; then
  record_alert warning "Memory usage ${mem_pct}% (${mem_used_mb}/${mem_total_mb} MiB) exceeds threshold ${MEM_WARN}%"
fi

if (( ${#disk_rows[@]} > 0 )); then
  for row in "${disk_rows[@]}"; do
    IFS=$'\t' read -r _ _ _ _ d_pct d_mount <<< "$row"
    if gt_num "$d_pct" "$DISK_CRIT"; then
      record_alert critical "Disk usage on ${d_mount} is ${d_pct}% (critical threshold ${DISK_CRIT}%)"
    elif gt_num "$d_pct" "$DISK_WARN"; then
      record_alert warning "Disk usage on ${d_mount} is ${d_pct}% (threshold ${DISK_WARN}%)"
    fi
  done
fi

format_text() {
  printf '[%s] host=%s status=%s cpu=%s%% mem=%s%% (%s/%s MiB) load=%s,%s,%s\n' \
    "$timestamp" "$host_name" "$status" "$cpu_pct" "$mem_pct" "$mem_used_mb" "$mem_total_mb" \
    "$load1" "$load5" "$load15"

  printf 'Filesystems:\n'
  local row d_fs d_tot d_used d_avail d_pct d_mount
  if (( ${#disk_rows[@]} > 0 )); then
    for row in "${disk_rows[@]}"; do
      IFS=$'\t' read -r d_fs d_tot d_used d_avail d_pct d_mount <<< "$row"
      printf '  %-24s %3s%%  used=%sK avail=%sK fs=%s\n' "$d_mount" "$d_pct" "$d_used" "$d_avail" "$d_fs"
    done
  fi

  printf 'Top 5 processes by memory:\n'
  local p_row p_pid p_mem p_cpu p_cmd
  if (( ${#proc_rows[@]} > 0 )); then
    for p_row in "${proc_rows[@]}"; do
      IFS=$'\t' read -r p_pid p_mem p_cpu p_cmd <<< "$p_row"
      printf '  pid=%-7s mem=%5s%% cpu=%5s%% cmd=%s\n' "$p_pid" "$p_mem" "$p_cpu" "$p_cmd"
    done
  fi

  local alert
  if (( ${#alerts[@]} > 0 )); then
    for alert in "${alerts[@]}"; do
      printf '%s\n' "$alert"
    done
  fi
}

format_json() {
  local disks_json="" first=true row d_fs d_tot d_used d_avail d_pct d_mount
  if (( ${#disk_rows[@]} > 0 )); then
    for row in "${disk_rows[@]}"; do
      IFS=$'\t' read -r d_fs d_tot d_used d_avail d_pct d_mount <<< "$row"
      if "$first"; then first=false; else disks_json+=","; fi
      disks_json+=$(printf '{"filesystem":%s,"mount":%s,"total_kb":%s,"used_kb":%s,"avail_kb":%s,"percent":%s}' \
        "$(json_escape "$d_fs")" "$(json_escape "$d_mount")" "$d_tot" "$d_used" "$d_avail" "$d_pct")
    done
  fi

  local procs_json="" p_row p_pid p_mem p_cpu p_cmd
  first=true
  if (( ${#proc_rows[@]} > 0 )); then
    for p_row in "${proc_rows[@]}"; do
      IFS=$'\t' read -r p_pid p_mem p_cpu p_cmd <<< "$p_row"
      if "$first"; then first=false; else procs_json+=","; fi
      procs_json+=$(printf '{"pid":%s,"mem_percent":%s,"cpu_percent":%s,"command":%s}' \
        "$p_pid" "$p_mem" "$p_cpu" "$(json_escape "$p_cmd")")
    done
  fi

  local alerts_json="" alert
  first=true
  if (( ${#alerts[@]} > 0 )); then
    for alert in "${alerts[@]}"; do
      if "$first"; then first=false; else alerts_json+=","; fi
      alerts_json+=$(json_escape "$alert")
    done
  fi

  printf '{"timestamp":%s,"hostname":%s,"status":%s,"exit_code":%s,"cpu_percent":%s,"memory":{"used_mb":%s,"total_mb":%s,"percent":%s},"load_average":{"1m":%s,"5m":%s,"15m":%s},"disks":[%s],"top_processes":[%s],"alerts":[%s]}\n' \
    "$(json_escape "$timestamp")" "$(json_escape "$host_name")" "$(json_escape "$status")" "$exit_code" \
    "$cpu_pct" "$mem_used_mb" "$mem_total_mb" "$mem_pct" \
    "$load1" "$load5" "$load15" "$disks_json" "$procs_json" "$alerts_json"
}

send_webhook() {
  local url="$1"
  local text="$2"
  if ! command -v curl >/dev/null 2>&1; then
    printf 'warning: curl not found, skipping webhook alert\n' >&2
    return 0
  fi
  local payload
  if [[ "$url" == *discord.com/api/webhooks/* || "$url" == *discordapp.com/api/webhooks/* ]]; then
    payload=$(printf '{"content":%s}' "$(json_escape "$text")")
  else
    payload=$(printf '{"text":%s}' "$(json_escape "$text")")
  fi
  if ! curl -fsS -m 5 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1; then
    printf 'warning: failed to deliver webhook alert\n' >&2
  fi
}

log_dir=$(dirname "$LOG_FILE")
mkdir -p "$log_dir"
rotate_log "$LOG_FILE" "$MAX_LOG_BYTES" "$MAX_LOG_BACKUPS"

if "$JSON_OUTPUT"; then
  json_line=$(format_json)
  printf '%s\n' "$json_line"
  printf '%s\n' "$json_line" >> "$LOG_FILE"
  if (( ${#alerts[@]} > 0 )); then
    for alert in "${alerts[@]}"; do
      printf '%s\n' "$alert" >&2
    done
  fi
else
  report=$(format_text)
  printf '%s\n' "$report"
  printf '%s\n\n' "$report" >> "$LOG_FILE"
fi

if [[ -n "${HEALTH_WEBHOOK_URL:-}" ]] && (( exit_code >= 1 )); then
  alert_summary=$(printf '%s on %s (%s): cpu=%s%% mem=%s%% | %s' \
    "${status^^}" "$host_name" "$timestamp" "$cpu_pct" "$mem_pct" "${alerts[*]}")
  send_webhook "$HEALTH_WEBHOOK_URL" "$alert_summary"
fi

exit "$exit_code"
