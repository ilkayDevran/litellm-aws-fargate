#!/usr/bin/env bash
#
# Deploy (or update) the LiteLLM proxy CloudFormation stack.
#
# Required env:
#   DOMAIN_NAME       e.g. litellm.sirket.com
#   HOSTED_ZONE_ID    e.g. Z1234567890ABC
#
# Optional env:
#   AWS_REGION        default us-east-1
#   STACK_NAME        default litellm-proxy
#   ECR_REPO_NAME     default litellm-proxy
#   IMAGE_TAG         default latest
#   DB_INSTANCE_CLASS default db.t4g.small
#   VPC_ID            default: auto-discover default VPC of the region
#   SUBNET_IDS        default: auto-discover default VPC subnets (comma-separated)
#   OWNER             default platform-team — applied as Owner tag to all resources
#   STACK_STATE       default Prod        — applied as StackState tag (Dev/Staging/Prod)
#
# Interactive (prompts y/n, default Y; skipped if env set or no TTY):
#   ENABLE_WAF        "true" attaches AWS WAF (IP reputation + Bearer-sk format
#                     on inference paths + KnownBadInputs managed rule)
#   SKIP_BUILD        "true" reuses existing ECR image (no docker build/push)
#                     -> set either in env/.env.local to skip the prompt (CI)
#
# On first run, randomly generates DB_PASSWORD / MASTER_KEY / UI_PASSWORD and
# stores them in Secrets Manager. On subsequent runs, reuses values from
# Secrets Manager so the stack update is idempotent.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-litellm-proxy}"
ECR_REPO_NAME="${ECR_REPO_NAME:-litellm-proxy}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t4g.small}"
OWNER="${OWNER:-platform-team}"
STACK_STATE="${STACK_STATE:-Prod}"

# Interactive y/n for these two, default Y. If already set via env -> no prompt
# (keeps scriptable/CI). If no TTY -> use default Y silently (no hang).
ask_yn() {
  # $1 prompt  $2 varname  ($default is always y here)
  local prompt="$1" varname="$2" current ans
  current="${!varname:-}"
  if [[ -n "$current" ]]; then return; fi          # explicit env -> respect it
  if [[ ! -t 0 ]]; then printf -v "$varname" 'true'; return; fi  # no TTY -> default Y=true
  read -r -p "$prompt [Y/n] " ans
  ans="${ans:-y}"
  case "$ans" in
    [Yy]*) printf -v "$varname" 'true' ;;
    *)     printf -v "$varname" 'false' ;;
  esac
}
ask_yn "WAF aktif olsun mu? (IP reputation + Bearer-sk + KnownBadInputs)" ENABLE_WAF
ask_yn "Docker build atlansın mı? (Y = sadece CFN; N = image rebuild+push)" SKIP_BUILD
SKIP_BUILD="${SKIP_BUILD:-false}"
ENABLE_WAF="${ENABLE_WAF:-false}"

DOMAIN_NAME="${DOMAIN_NAME:?set DOMAIN_NAME=litellm.sirket.com}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:?set HOSTED_ZONE_ID=Zxxxxxxxxxxxxx}"
ALERT_EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL=you@company.com (for CloudWatch alarm notifications)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_FILE="${REPO_ROOT}/infra/litellm-stack.yaml"
DOCKER_CONTEXT="${REPO_ROOT}/litellm"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}:${IMAGE_TAG}"

# ---- 0. Resolve VPC + subnets (auto-discover default VPC if not provided) ----
if [[ -z "${VPC_ID:-}" ]]; then
  VPC_ID="$(aws ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "${REGION}")"
  if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
    echo "ERROR: no default VPC found in ${REGION}. Set VPC_ID env explicitly." >&2
    exit 1
  fi
fi

if [[ -z "${SUBNET_IDS:-}" ]]; then
  SUBNET_IDS="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --query 'Subnets[*].SubnetId' --output text --region "${REGION}" \
    | tr '[:space:]' ',' | sed 's/,$//')"
  if [[ -z "${SUBNET_IDS}" ]]; then
    # Fallback: any subnets in the VPC
    SUBNET_IDS="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[*].SubnetId' --output text --region "${REGION}" \
      | tr '[:space:]' ',' | sed 's/,$//')"
  fi
  SUBNET_COUNT="$(echo "${SUBNET_IDS}" | tr ',' '\n' | grep -c .)"
  if (( SUBNET_COUNT < 2 )); then
    echo "ERROR: need 2+ subnets in ${VPC_ID}, found ${SUBNET_COUNT}. Set SUBNET_IDS explicitly." >&2
    exit 1
  fi
fi

echo "▸ Region:     ${REGION}"
echo "▸ Stack:      ${STACK_NAME}"
echo "▸ Domain:     ${DOMAIN_NAME}"
echo "▸ VPC:        ${VPC_ID}"
echo "▸ Subnets:    ${SUBNET_IDS}"
echo "▸ ECR image:  ${IMAGE_URI}"
echo

# ---- 1. Ensure ECR repo exists ----
echo "▸ Ensuring ECR repository '${ECR_REPO_NAME}' exists..."
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository \
       --repository-name "${ECR_REPO_NAME}" \
       --image-scanning-configuration scanOnPush=true \
       --image-tag-mutability MUTABLE \
       --region "${REGION}" >/dev/null

# ---- 2. Build & push image (unless skipped) ----
if [[ "${SKIP_BUILD}" != "true" ]]; then
  echo "▸ Logging into ECR..."
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}" >/dev/null

  echo "▸ Building image..."
  docker build --platform linux/amd64 -t "${IMAGE_URI}" "${DOCKER_CONTEXT}"

  echo "▸ Pushing image..."
  docker push "${IMAGE_URI}"
else
  echo "▸ SKIP_BUILD=true → skipping docker build/push"
fi

# ---- 3. Resolve / generate secret values ----
get_or_create_secret() {
  local secret_name="$1"
  local generator="$2"
  if aws secretsmanager describe-secret --secret-id "${secret_name}" --region "${REGION}" >/dev/null 2>&1; then
    aws secretsmanager get-secret-value --secret-id "${secret_name}" --region "${REGION}" --query SecretString --output text
  else
    eval "${generator}"
  fi
}

DB_PASSWORD="$(get_or_create_secret "${STACK_NAME}/db-password" "openssl rand -base64 32 | tr -d '/+=\\n@\"' | head -c 32")"
MASTER_KEY="$(get_or_create_secret "${STACK_NAME}/master-key" "echo sk-\$(openssl rand -hex 24)")"
UI_PASSWORD="$(get_or_create_secret "${STACK_NAME}/ui-password" "openssl rand -base64 18 | tr -d '/+=\\n'")"

# ---- 4. Deploy CFN stack ----
echo "▸ Deploying CloudFormation stack..."
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --tags \
    Owner="${OWNER}" \
    ProjectName="${STACK_NAME}" \
    StackState="${STACK_STATE}" \
  --parameter-overrides \
    DomainName="${DOMAIN_NAME}" \
    HostedZoneId="${HOSTED_ZONE_ID}" \
    AlertEmail="${ALERT_EMAIL}" \
    VpcId="${VPC_ID}" \
    SubnetIds="${SUBNET_IDS}" \
    ImageUri="${IMAGE_URI}" \
    DBPassword="${DB_PASSWORD}" \
    MasterKey="${MASTER_KEY}" \
    UIUsername=admin \
    UIPassword="${UI_PASSWORD}" \
    DBInstanceClass="${DB_INSTANCE_CLASS}" \
    EnableWAF="${ENABLE_WAF}"

# ---- 4b. Force a new ECS deployment when a fresh image was built ----
# The image tag is immutable (":latest"), so CloudFormation sees no change to the
# task definition and will NOT roll the service on its own. If we just built and
# pushed a new image (config.yaml / Dockerfile change), force a new deployment so
# the running task actually pulls it.
if [[ "${SKIP_BUILD}" != "true" ]]; then
  echo "▸ Forcing ECS deployment to pull the freshly built image..."
  aws ecs update-service \
    --cluster "${STACK_NAME}-cluster" \
    --service "${STACK_NAME}-service" \
    --force-new-deployment \
    --region "${REGION}" \
    --query 'service.deployments[0].{Status:status,Rollout:rolloutState,Desired:desiredCount}' \
    --output table
  echo "▸ Waiting for service to stabilize (this can take a few minutes)..."
  aws ecs wait services-stable \
    --cluster "${STACK_NAME}-cluster" \
    --services "${STACK_NAME}-service" \
    --region "${REGION}" && echo "✓ Service stable on new image"
fi

# ---- 5. Output ----
echo
echo "▸ Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

cat <<EOF

✓ Done. Credentials (already saved in Secrets Manager):
  Proxy URL :  https://${DOMAIN_NAME}
  UI URL    :  https://${DOMAIN_NAME}/ui
  UI login  :  admin / ${UI_PASSWORD}
  MASTER_KEY:  ${MASTER_KEY}

Next:
  1) Open https://${DOMAIN_NAME}/ui (admin / UI password above)
  2) Models → Add new model:
       - Bedrock: provider Amazon Bedrock, credentials boş (IAM task role)
       - Vertex:  provider Vertex AI, vertex_credentials alanına SA JSON'u yapıştır
  3) Virtual Keys → Create New Key (her proje için, budget + rate limit ile)
  4) Test:  LITELLM_API_KEY=sk-... python examples/proxy_provider.py
EOF
