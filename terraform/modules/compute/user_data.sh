#!/usr/bin/env bash
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

mkdir -p /etc/devops-stack
cat > /etc/devops-stack/deploy.env <<'EOF'
APP_ENV=${environment}
CW_LOG_GROUP=${cw_log_group}
EOF
chmod 0644 /etc/devops-stack/deploy.env

ECR_REGISTRY="${ecr_registry}"
APP_IMAGE="${app_image}"

if aws ecr get-login-password --region "${aws_region}" | docker login --username AWS --password-stdin "$ECR_REGISTRY" \
  && docker pull "$APP_IMAGE"; then
  docker rm -f devops-stack 2>/dev/null || true
  docker run -d --name devops-stack \
    --restart unless-stopped \
    --read-only \
    --cap-drop ALL \
    -p 8080:8080 \
    -e PORT=8080 \
    -e LOG_LEVEL=info \
    -e "APP_ENV=${environment}" \
    -e "APP_VERSION=${app_version}" \
    --log-driver=awslogs \
    --log-opt "awslogs-region=${aws_region}" \
    --log-opt "awslogs-group=${cw_log_group}" \
    --log-opt "awslogs-stream=devops-stack" \
    --log-opt mode=non-blocking \
    --log-opt max-buffer-size=4m \
    "$APP_IMAGE"
else
  echo "Image $APP_IMAGE not yet in ECR; Docker ready for SSM deployment."
fi
