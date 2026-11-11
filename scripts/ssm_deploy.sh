#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?missing IMAGE}"
: "${TAG:?missing TAG}"
: "${ECR_REGISTRY:?missing ECR_REGISTRY}"
: "${AWS_REGION:?missing AWS_REGION}"
: "${EC2_INSTANCE_ID:?missing EC2_INSTANCE_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SCRIPT="${SCRIPT_DIR}/remote_deploy.sh"

PAYLOAD=$(
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export IMAGE=%q TAG=%q AWS_REGION=%q ECR_REGISTRY=%q\n' \
      "$IMAGE" "$TAG" "$AWS_REGION" "$ECR_REGISTRY"
    tail -n +2 "$REMOTE_SCRIPT"
  } | jq -Rs '{commands: split("\n")}'
)

CMD_ID=$(aws ssm send-command \
  --instance-ids "$EC2_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "Deploy ${IMAGE}:${TAG}" \
  --parameters "$PAYLOAD" \
  --query 'Command.CommandId' \
  --output text)

set +e
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$EC2_INSTANCE_ID"
WAIT_RC=$?
set -e

INVOCATION=$(aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$EC2_INSTANCE_ID" \
  --output json)

STATUS=$(printf '%s' "$INVOCATION" | jq -r '.Status')
printf '%s' "$INVOCATION" | jq -r '.StandardOutputContent // empty'
STDERR=$(printf '%s' "$INVOCATION" | jq -r '.StandardErrorContent // empty')
if [ -n "$STDERR" ]; then
  printf '%s\n' "$STDERR" >&2
fi

if [ "$WAIT_RC" -ne 0 ] || [ "$STATUS" != "Success" ]; then
  echo "SSM deploy finished with status: $STATUS" >&2
  exit 1
fi
