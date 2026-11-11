#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-devops-stack}"
NAMESPACE="${NAMESPACE:-devops-stack}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-0.34.1}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.15.0}"
RELOADER_CHART_VERSION="${RELOADER_CHART_VERSION:-2.2.19}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi

usage() {
  cat <<'EOF'
Usage: k8s_local.sh <command>

Manage a local k3d cluster for devops-stack (Helm + Vault + ESO + Reloader,
plus plain k8s/ YAML reference).

Commands:
  up      Build 0.1.0/0.2.0 images, create k3d cluster, install Vault/ESO/Reloader,
          configure Vault Kubernetes Auth + staging secret, and install Helm chart
  demo    Rotate secret in Vault (triggers Reloader), upgrade Helm to 0.2.0, and rollback
  plain   Deploy plain k8s/ manifests (imperative Secret) + test set image & rollout undo
  down    Delete the local k3d cluster
  -h, --help  Show this help message
EOF
}

require_tools() {
  local cmd
  for cmd in docker k3d kubectl helm curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf 'error: missing required tool: %s\n' "$cmd" >&2
      exit 1
    }
  done
}

wait_for_http() {
  local url="${1:-http://localhost:8080}"
  for _ in $(seq 1 30); do
    if curl -fsS "${url}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'error: timed out waiting for %s/health\n' "$url" >&2
  return 1
}

wait_for_version() {
  local expected="$1"
  local url="${2:-http://localhost:8080}"
  local images body
  for _ in $(seq 1 30); do
    images="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=devops-stack \
      -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null | sort -u)"
    if [[ "$images" == "devops-stack:${expected}" ]]; then
      break
    fi
    sleep 1
  done
  for _ in $(seq 1 20); do
    body="$(curl -fsS "${url}/" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q "\"version\":\"${expected}\""; then
      printf '%s\n' "$body"
      return 0
    fi
    sleep 1
  done
  printf 'error: timed out waiting for version %s (last: %s)\n' "$expected" "$body" >&2
  return 1
}

cmd_up() {
  require_tools
  docker build --build-arg APP_VERSION=0.1.0 -t devops-stack:0.1.0 ./app
  docker build --build-arg APP_VERSION=0.2.0 -t devops-stack:0.2.0 ./app

  if ! k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    k3d cluster create "$CLUSTER_NAME" -p "8080:80@loadbalancer" --wait
  fi
  k3d image import devops-stack:0.1.0 devops-stack:0.2.0 -c "$CLUSTER_NAME"

  helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
  helm repo update hashicorp external-secrets stakater

  helm upgrade --install vault hashicorp/vault --version "$VAULT_CHART_VERSION" \
    -n vault --create-namespace --set server.dev.enabled=true --set injector.enabled=false --wait --timeout 10m
  helm upgrade --install external-secrets external-secrets/external-secrets --version "$ESO_CHART_VERSION" \
    -n external-secrets --create-namespace --wait --timeout 10m
  helm upgrade --install reloader stakater/reloader --version "$RELOADER_CHART_VERSION" \
    -n reloader --create-namespace --wait --timeout 10m

  local token
  token="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  kubectl -n vault exec -i vault-0 -- sh -s "$NAMESPACE" "$token" <<'EOF'
set -eu
ns="$1"
tok="$2"
vault auth list -format=json | grep -q '"kubernetes/"' || vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
vault policy write devops-stack-read - <<'POLICY'
path "secret/data/devops-stack/*" { capabilities = ["read"] }
path "secret/data/devops-stack" { capabilities = ["read"] }
POLICY
vault write auth/kubernetes/role/devops-stack \
  bound_service_account_names=devops-stack-eso \
  bound_service_account_namespaces="$ns" \
  policies=devops-stack-read ttl=1h
vault kv put "secret/devops-stack/staging" API_TOKEN="$tok"
EOF

  helm upgrade --install devops-stack ./charts/devops-stack \
    -n "$NAMESPACE" --create-namespace -f charts/devops-stack/values-staging.yaml --wait
  kubectl -n "$NAMESPACE" wait --for=condition=Ready externalsecret/devops-stack --timeout=60s

  wait_for_http
  curl -fsS http://localhost:8080/health && printf '\n'
  wait_for_version 0.1.0
}

cmd_demo() {
  require_tools
  local old_rv new_rv old_gen new_gen rotated
  old_rv="$(kubectl -n "$NAMESPACE" get secret devops-stack-secrets -o jsonpath='{.metadata.resourceVersion}')"
  old_gen="$(kubectl -n "$NAMESPACE" get deployment devops-stack -o jsonpath='{.metadata.generation}')"
  new_rv="$old_rv"
  new_gen="$old_gen"
  rotated="rotated-$(date +%s)"
  kubectl -n vault exec vault-0 -- vault kv put secret/devops-stack/staging API_TOKEN="$rotated"
  for _ in $(seq 1 30); do
    new_rv="$(kubectl -n "$NAMESPACE" get secret devops-stack-secrets -o jsonpath='{.metadata.resourceVersion}')"
    new_gen="$(kubectl -n "$NAMESPACE" get deployment devops-stack -o jsonpath='{.metadata.generation}')"
    if [[ "$new_rv" != "$old_rv" && "$new_gen" != "$old_gen" ]]; then
      printf 'Secret rotated (%s -> %s); Reloader bumped Deployment generation (%s -> %s)\n' \
        "$old_rv" "$new_rv" "$old_gen" "$new_gen"
      break
    fi
    sleep 1
  done
  if [[ "$new_gen" == "$old_gen" ]]; then
    printf 'error: Reloader did not trigger Deployment rollout after secret rotation\n' >&2
    return 1
  fi
  kubectl -n "$NAMESPACE" rollout status deployment/devops-stack --timeout=90s

  helm upgrade devops-stack ./charts/devops-stack -n "$NAMESPACE" \
    -f charts/devops-stack/values-staging.yaml --set image.tag=0.2.0 --wait
  wait_for_version 0.2.0

  helm rollback devops-stack -n "$NAMESPACE" --wait
  wait_for_version 0.1.0
  helm history devops-stack -n "$NAMESPACE"
}

cmd_plain() {
  require_tools
  helm uninstall devops-stack -n "$NAMESPACE" --wait >/dev/null 2>&1 || true

  local token
  token="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  kubectl apply -f k8s/00-namespace.yaml
  kubectl create secret generic devops-stack-secrets -n "$NAMESPACE" \
    --from-literal=API_TOKEN="$token" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f k8s/
  kubectl -n "$NAMESPACE" rollout status deployment/devops-stack --timeout=90s

  kubectl -n "$NAMESPACE" set image deployment/devops-stack app=devops-stack:0.2.0
  kubectl -n "$NAMESPACE" rollout status deployment/devops-stack --timeout=90s
  wait_for_version 0.2.0

  kubectl -n "$NAMESPACE" rollout undo deployment/devops-stack
  kubectl -n "$NAMESPACE" rollout status deployment/devops-stack --timeout=90s
  wait_for_version 0.1.0
}

cmd_down() {
  command -v k3d >/dev/null 2>&1 || exit 0
  k3d cluster delete "$CLUSTER_NAME"
}

case "${1:-}" in
  up) cmd_up ;;
  demo) cmd_demo ;;
  plain) cmd_plain ;;
  down) cmd_down ;;
  -h|--help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
