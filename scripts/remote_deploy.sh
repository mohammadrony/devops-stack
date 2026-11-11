#!/usr/bin/env bash
set -euo pipefail

# Expects IMAGE, TAG, AWS_REGION, and ECR_REGISTRY exported by scripts/ssm_deploy.sh.
if [ -f /etc/devops-stack/deploy.env ]; then
  # shellcheck source=/dev/null
  . /etc/devops-stack/deploy.env
fi

APP_ENV="${APP_ENV:-production}"
NEW_IMAGE="${IMAGE}:${TAG}"
PREV_IMAGE=$(docker inspect --format='{{.Config.Image}}' devops-stack 2>/dev/null || true)

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker pull "$NEW_IMAGE"

run_app() {
  local img="$1" ver="$2"
  local -a log_opts=()
  if [ -n "${CW_LOG_GROUP:-}" ]; then
    log_opts=(
      --log-driver=awslogs
      --log-opt "awslogs-region=${AWS_REGION}"
      --log-opt "awslogs-group=${CW_LOG_GROUP}"
      --log-opt "awslogs-stream=devops-stack"
      --log-opt mode=non-blocking
      --log-opt max-buffer-size=4m
    )
  fi

  docker stop devops-stack 2>/dev/null || true
  docker rm devops-stack 2>/dev/null || true
  docker run -d --name devops-stack \
    --restart unless-stopped \
    --read-only \
    --cap-drop ALL \
    -p 8080:8080 \
    -e PORT=8080 \
    -e LOG_LEVEL=info \
    -e "APP_ENV=${APP_ENV}" \
    -e "APP_VERSION=${ver}" \
    "${log_opts[@]+"${log_opts[@]}"}" \
    "$img"
}

run_app "$NEW_IMAGE" "$TAG"

healthy=false
for _ in $(seq 1 12); do
  if curl -fsS http://127.0.0.1:8080/health >/dev/null; then
    healthy=true
    break
  fi
  sleep 2
done

if [ "$healthy" != "true" ]; then
  echo "Smoke test failed for $NEW_IMAGE; rolling back to ${PREV_IMAGE:-none}" >&2
  docker logs devops-stack --tail 50 || true
  if [ -n "$PREV_IMAGE" ]; then
    run_app "$PREV_IMAGE" "${PREV_IMAGE##*:}"
    curl -fsS --retry 5 --retry-delay 2 http://127.0.0.1:8080/health >/dev/null
  else
    docker stop devops-stack 2>/dev/null || true
    docker rm devops-stack 2>/dev/null || true
  fi
  exit 1
fi

echo "Deployed $NEW_IMAGE and passed /health smoke test"
