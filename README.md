# devops-stack

Go HTTP service with Prometheus metrics, structured JSON logs, and containerized local setup.

## Run Locally

Requires Docker and Docker Compose (Go 1.26+ optional for running tests directly).

```bash
docker compose up -d --build
curl -s http://localhost:8080/
curl -s http://localhost:8080/health
curl -s http://localhost:8080/metrics | head -n 20
docker compose down
```

Tests and lint checks:

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

| Route | Behavior |
| :--- | :--- |
| `GET /` | Service info JSON (`message`, `status`, `version`) |
| `GET /health` | `200` when ready, `503` during `SIGTERM` shutdown |
| `GET /metrics` | Prometheus metrics (`http_requests_total`, `http_errors_total`, `http_request_duration_seconds`) |

## Container Image

Multi-stage build (`golang:1.26-alpine` to `gcr.io/distroless/static-debian12:nonroot`, both pinned by digest), running as UID/GID `65532` with a built-in `-healthcheck` flag. Final image size: **19.3 MB**.
