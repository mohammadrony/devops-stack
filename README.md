# devops-stack

Go HTTP service with Prometheus metrics, structured JSON logs, containerized local setup, and an observability stack.

## Run Locally

Requires Docker and Docker Compose (Go 1.27+ optional for running tests directly).

### App Only

```bash
docker compose up -d --build
curl -s http://localhost:8080/
curl -s http://localhost:8080/health
curl -s http://localhost:8080/metrics | head -n 20
docker compose down
```

### Full Observability Stack

```bash
cp .env.example .env   # set GRAFANA_ADMIN_PASSWORD before starting
make up-monitoring
```

Access Grafana at `http://localhost:3000` with the credentials from `.env`. Prometheus, Loki, Alloy, Node Exporter, and cAdvisor sit on an `internal: true` Docker network (`monitoring`) with no host ports exposed.

Stop the stack:

```bash
make down-monitoring
```

### Tests & Lint

```bash
make test
make lint
```

## Configuration & Endpoints

| Env Var | Default | Purpose |
| :--- | :--- | :--- |
| `PORT` | `8080` | Listen port (`1`–`65535`) |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, or `error` |
| `APP_ENV` | `local` | Environment field in JSON logs |
| `APP_VERSION` | `0.1.0` | Version returned by `GET /` |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | — | Grafana admin password |

| Route | Behavior |
| :--- | :--- |
| `GET /` | Service info JSON (`message`, `status`, `version`) |
| `GET /health` | `200` when ready, `503` during `SIGTERM` shutdown |
| `GET /metrics` | Prometheus metrics (`http_requests_total`, `http_errors_total`, `http_request_duration_seconds`) |

## Container Image

Multi-stage build (`golang:1.27-alpine` to `gcr.io/distroless/static-debian12:nonroot`, both pinned by digest), running as UID/GID `65532` with a built-in `-healthcheck` flag. Final image size: **20.2 MB**.

## Observability Stack

Defined in [docker-compose.monitoring.yml](docker-compose.monitoring.yml) with all images pinned and configs provisioned as code under [monitoring/](monitoring/):

- **Prometheus** (`v3.16.0`): scrapes `app:8080/metrics`, `node-exporter:9100`, and `cadvisor:8080` every `15s`; retention set to `15d` / `1GB`.
- **Grafana Alloy** (`v1.21.3`) + **Loki** (`3.7.9`): discovers containers via Docker socket, parses `app` JSON stdout logs, and stores logs with `168h` (`7d`) retention via Loki's compactor.
- **Grafana** (`13.3.1`): auto-provisions Prometheus/Loki data sources and three dashboards (`Application`, `Host`, `Containers`).

### Log Label Cardinality Choices

Alloy promotes only four bounded stream labels: `container`, `service`, `level` (`DEBUG`/`INFO`/`WARN`/`ERROR`), and normalized `path` (`/`, `/health`, `/metrics`, `/other`). Unbounded fields such as `uri` (raw request path), `duration_ms`, and timestamps stay inside the JSON log body and are queried at read time via LogQL `| json` so Loki index cardinality stays low.

### Alerting Rules

Defined in [monitoring/prometheus/alerts.yml](monitoring/prometheus/alerts.yml):

| Alert | Condition | `for` | Why |
| :--- | :--- | :--- | :--- |
| `AppInstanceDown` | `up{job="devops-stack"} == 0` | `1m` | Four failed `15s` scrapes filter transient restarts while catching real outages quickly. |
| `HighErrorRate` | `http_errors_total` / `http_requests_total` > `5%` (min 5 reqs/5m) | `2m` | Minimum volume avoids low-traffic noise; `2m` ignores isolated client typos. |
| `HostDiskUsageHigh` | Root filesystem used > `80%` | `5m` | Leaves 20% headroom before Docker/log writes fail; `5m` rides out temp build caches. |
| `ContainerMemoryNearLimit` | Working set / cgroup limit > `85%` | `2m` | Warns ahead of OOM kills while ignoring brief Go GC spikes. |

### Host Mounts & Privileges

| Container | Mount / Privilege | Reason |
| :--- | :--- | :--- |
| `node-exporter` | `/proc`, `/sys`, `/` (`:ro`), `pid: host` | Read host CPU, memory, disk, network, and process counters without writing to the host. |
| `cadvisor` | `/`, `/var/run`, `/sys`, `/var/lib/docker`, `/dev/disk` (`:ro`), `/dev/kmsg`, `privileged: true` | Inspect cgroup v2 per-container CPU/memory stats and containerd snapshotter layers. |
| `alloy` | `/var/run/docker.sock` (`:ro`) | Discover running containers and tail stdout/stderr logs via Docker's API. |

### Dashboards

**Application** (includes metrics alongside the Loki logs panel):

![Application Dashboard](docs/images/dashboard-application.png)

**Host**:

![Host Dashboard](docs/images/dashboard-host.png)

**Containers**:

![Containers Dashboard](docs/images/dashboard-containers.png)

### Investigating an Error Spike

> *An error spike appears on the Application dashboard. How do you find the cause using these tools?*

1. Check **Error Rate (%)** and **Request Rate (req/s)** on the Application dashboard to identify the exact spike window and whether errors come from a known route (`/`) or unknown paths (`/other`).
2. Look at the adjacent **Application Logs (Loki)** panel over that same time range and narrow with `{service="app", level=~"WARN|ERROR"} | json` (filtering by `path` if needed).
3. Inspect the expanded JSON fields (`uri`, `status`, `duration_ms`) to see whether the spike is external 404 probing (`uri="/api/..."`) or internal 5xx failures on a live endpoint.
4. Check **Host** and **Containers** dashboards (CPU throttling, memory vs limit, or disk pressure) and Prometheus alert state to rule out infrastructure saturation or OOM restarts.

## Host Health Script

[scripts/system_health.sh](scripts/system_health.sh) collects CPU usage, memory usage, mounted filesystem disk usage, load average, and the top 5 processes by memory, appending each run to `health_log.txt` (with automatic rotation past 1 MiB across 3 backups).

```bash
./scripts/system_health.sh --help
./scripts/system_health.sh --disk 80 --cpu 90 --mem 85
./scripts/system_health.sh --json | jq .
```

| Exit Code | Meaning |
| :--- | :--- |
| `0` | All metrics below thresholds |
| `1` | One or more warning thresholds exceeded (`[WARNING]`) |
| `2` | One or more critical thresholds exceeded (`[CRITICAL]`, default `95%` or `--*-crit`) |
| `3` | Invalid arguments or unreadable `/proc` inputs |

### Scheduling (Every 5 Minutes)

Install the systemd service + timer from [scripts/systemd/](scripts/systemd/):

```bash
sudo install -m 0755 scripts/system_health.sh /usr/local/bin/system_health.sh
sudo cp scripts/systemd/system-health.service scripts/systemd/system-health.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now system-health.timer
```

`system-health.service` sets `SuccessExitStatus=1 2` so warning/critical health exits are logged without marking the scheduled unit as failed. Alternatively, copy [scripts/system-health.cron](scripts/system-health.cron) to `/etc/cron.d/system-health`.

## CI/CD Pipeline

Three workflows live under [.github/workflows/](.github/workflows/):

- **[ci.yml](.github/workflows/ci.yml)** (runs on every PR to `main`):
  - `gofmt`, `go vet`, and `go test -v -race` with per-function coverage summary posted to the workflow summary.
  - `hadolint` on [app/Dockerfile](app/Dockerfile), `shellcheck` (`v0.11.0`) on shell scripts, `terraform fmt`/`validate`, and Trivy IaC config scan.
  - Docker Buildx image build + Trivy image scan (summarizes `HIGH,CRITICAL`, fails on `CRITICAL`).
- **[cd.yml](.github/workflows/cd.yml)** (runs on push to `main` and manual dispatch):
  - Multi-architecture Buildx build (`linux/amd64`, `linux/arm64`) with GitHub Actions layer cache (`type=gha`).
  - Tags images with both the short commit SHA (`sha-<7chars>`) and the semantic version (`0.1.0` or latest `v*` git tag) — never `latest` alone.
  - When `AWS_DEPLOY_ENABLED` is `true`, authenticates to AWS via GitHub OIDC (no static access keys), pushes to Amazon ECR, and triggers [ssm_deploy.sh](scripts/ssm_deploy.sh) → [remote_deploy.sh](scripts/remote_deploy.sh) over AWS SSM to update the EC2 container, smoke-test `/health`, and automatically roll back to the previous image on failure.
- **[terraform-apply.yaml](.github/workflows/terraform-apply.yaml)** (manual `workflow_dispatch` only):
  - Runs `plan`, `apply`, or `destroy` against `staging` or `production` using the S3 backend (`use_lockfile = true`).
  - Restricted to the repository owner via `if: github.actor == github.repository_owner`, `workflow_dispatch` write-permission gating, and GitHub Environment targets (`staging`/`production`).

### Required GitHub Settings (for Live AWS Workflows)

Configure under **Settings → Secrets and variables → Actions** for live AWS workflows:

| Type | Name | Value |
| :--- | :--- | :--- |
| Secret | `AWS_ROLE_ARN` | OIDC IAM role ARN used by `cd.yml` (`github_actions_role_arn` output) |
| Secret | `AWS_TERRAFORM_ROLE_ARN` | OIDC IAM role ARN with infrastructure permissions for `terraform-apply.yaml` |
| Variable | `AWS_DEPLOY_ENABLED` | `true` (leave unset or `false` to build multi-arch without deploying) |
| Variable | `AWS_REGION` | Target AWS region (`ap-south-1`) |
| Variable | `ECR_REPOSITORY` | ECR repository name (`devops-stack`) |
| Variable | `EC2_INSTANCE_ID` | EC2 instance ID managed via AWS SSM (`i-...`) |
| Variable | `TF_STATE_BUCKET` | S3 bucket name for remote Terraform state (`terraform-apply.yaml`) |

## Infrastructure (Terraform)

Modular AWS configuration under [terraform/](terraform/) targeting `ap-south-1` (Mumbai):

- **[bootstrap/](terraform/bootstrap/)**: creates the encrypted, versioned S3 bucket for remote state (local state).
- **[modules/registry/](terraform/modules/registry/)**: ECR repository (`scan_on_push = true`, AES256 encryption, lifecycle retention).
- **[modules/compute/](terraform/modules/compute/)**: default VPC Amazon Linux 2023 EC2 (`t3.micro` in staging / `t3.small` in production), security group allowing only port `8080` inbound and DNS/`443` outbound (no SSH port `22`), IMDSv2 (`hop_limit = 1`), encrypted `gp3` root volume, least-privilege IAM instance profile (SSM + ECR pull + CloudWatch Logs write), CloudWatch Log Group with defined retention, and [user_data.sh](terraform/modules/compute/user_data.sh) shipping container logs via `awslogs`.
- **[modules/github_oidc/](terraform/modules/github_oidc/)**: GitHub OIDC deploy role restricted to `main` with scoped ECR push and SSM command permissions.
- **[environments/](terraform/environments/)**: `staging.tfvars` and `production.tfvars` with `.tfbackend.example` templates using S3-native state locking (`use_lockfile = true`, no DynamoDB table required).

### Provision & Destroy

```bash
# 1. Create the S3 remote-state bucket once per account/region
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

# 2. Configure staging backend using the output bucket name
cp terraform/environments/staging.tfbackend.example terraform/environments/staging.tfbackend

# 3. Initialize remote state (with S3 native locking) and deploy staging
terraform -chdir=terraform init -reconfigure -backend-config=environments/staging.tfbackend
terraform -chdir=terraform plan -var-file=environments/staging.tfvars
terraform -chdir=terraform apply -var-file=environments/staging.tfvars

# 4. Preview production (set AWS credentials / backend key for production first)
terraform -chdir=terraform plan -var-file=environments/production.tfvars

# 5. Clean up when finished testing
terraform -chdir=terraform destroy -var-file=environments/staging.tfvars
terraform -chdir=terraform/bootstrap destroy
```

Pass `-var="create_oidc_provider=false"` if `token.actions.githubusercontent.com` already exists in your AWS account.

### Trivy Scan Exceptions

Intentional exceptions in [terraform/.trivyignore.yaml](terraform/.trivyignore.yaml):

- **AES256 instead of KMS CMKs (`AVD-AWS-0017`, `0033`, `0132`)**: AWS-managed server-side encryption incurs no key charge, avoiding $1/month per custom KMS key across CloudWatch, ECR, and S3.
- **Public HTTPS egress & HTTP ingress (`AVD-AWS-0104`, `0107`)**: Outbound `443` lets EC2 reach AWS SSM, ECR, and CloudWatch APIs without paid VPC Interface Endpoints; inbound `8080` exposes the service endpoint (narrow via `-var="allowed_cidr=..."`).
- **IAM wildcard on `ecr:GetAuthorizationToken` (`AVD-AWS-0057`)**: AWS IAM does not support resource-level ARN scoping for `ecr:GetAuthorizationToken`; pull/push actions are scoped strictly to the repo ARN.
- **Mutable ECR tags & omitted S3 access-log bucket (`AVD-AWS-0031`, `0089`)**: `MUTABLE` allows re-tagging base `0.1.0` until release tags increment, while SSM deploys pin `sha-*` tags; a separate access-log bucket is omitted for single-account state storage.

### Verified AWS Evidence

![Terraform S3 Remote State](docs/images/terraform-s3-state.png)

![CloudWatch Log Group and Stream](docs/images/terraform-cloudwatch-logs.png)

<details>
<summary>Verified ap-south-1 plan, apply, S3 lock, and CloudWatch Logs output</summary>

```text
# bootstrap apply
Plan: 4 to add, 0 to change, 0 to destroy.
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
state_bucket_name = "devops-stack-tfstate-<account-id>-ap-south-1"

# staging plan (create_oidc_provider=false)
Plan: 15 to add, 0 to change, 0 to destroy.

# staging apply outputs
app_url = "http://3.111.147.35:8080"
aws_region = "ap-south-1"
cloudwatch_log_group = "/aws/ec2/devops-stack-staging"
ec2_instance_id = "i-0742125fe401ff0dd"
ecr_repository_name = "devops-stack"

# HTTP smoke check & CloudWatch Logs
$ curl -fsS http://3.111.147.35:8080/health
{"status":"healthy"}
$ curl -fsS http://3.111.147.35:8080/
{"message":"Hello from DevOps Task!","status":"running","version":"0.1.0"}
$ aws --region ap-south-1 logs get-log-events --log-group-name /aws/ec2/devops-stack-staging --log-stream-name devops-stack
{"time":"2026-11-11T02:42:58.447365138Z","level":"INFO","msg":"server_started","port":"8080","env":"staging","version":"0.1.0"}
{"time":"2026-11-11T02:43:03.106836771Z","level":"INFO","msg":"http_request","env":"staging","version":"0.1.0","method":"GET","path":"/","uri":"/","status":200,"duration_ms":0.064}
```

</details>
