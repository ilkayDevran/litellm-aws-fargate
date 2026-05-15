#!/usr/bin/env bash
#
# Create a LiteLLM virtual key bound to a specific project/team.
# Each key gets its own RPM/TPM/budget — use this instead of IP rate limits.
#
# Usage:
#   ./create-virtual-key.sh proj-backend          # defaults: 60 rpm, 100k tpm, $50/mo
#   KEY_ALIAS=local-dev RPM_LIMIT=30 TPM_LIMIT=50000 MAX_BUDGET=10 ./create-virtual-key.sh
#
# Requires: PROXY_URL + MASTER_KEY env, or DOMAIN_NAME + automatic master key
# resolution from Secrets Manager.

set -euo pipefail

KEY_ALIAS="${1:-${KEY_ALIAS:?provide key alias as arg or KEY_ALIAS env}}"
MODELS="${MODELS:-claude-sonnet-bedrock,gemini-vertex}"
RPM_LIMIT="${RPM_LIMIT:-60}"
TPM_LIMIT="${TPM_LIMIT:-100000}"
MAX_BUDGET="${MAX_BUDGET:-50}"        # USD per budget_duration
BUDGET_DURATION="${BUDGET_DURATION:-30d}"
TEAM_ID="${TEAM_ID:-}"

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-litellm-proxy}"

if [[ -z "${PROXY_URL:-}" ]]; then
  : "${DOMAIN_NAME:?set DOMAIN_NAME or PROXY_URL}"
  PROXY_URL="https://${DOMAIN_NAME}"
fi

if [[ -z "${MASTER_KEY:-}" ]]; then
  MASTER_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "${STACK_NAME}/master-key" \
    --region "${REGION}" \
    --query SecretString --output text)"
fi

IFS=',' read -ra MODEL_ARRAY <<< "${MODELS}"
MODELS_JSON="$(printf '"%s",' "${MODEL_ARRAY[@]}" | sed 's/,$//')"

PAYLOAD=$(cat <<EOF
{
  "key_alias": "${KEY_ALIAS}",
  "models": [${MODELS_JSON}],
  "rpm_limit": ${RPM_LIMIT},
  "tpm_limit": ${TPM_LIMIT},
  "max_budget": ${MAX_BUDGET},
  "budget_duration": "${BUDGET_DURATION}"$( [[ -n "${TEAM_ID}" ]] && echo ", \"team_id\": \"${TEAM_ID}\"" )
}
EOF
)

echo "▸ Creating key '${KEY_ALIAS}' at ${PROXY_URL}..."
RESPONSE="$(curl -sS -X POST "${PROXY_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")"

echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"
