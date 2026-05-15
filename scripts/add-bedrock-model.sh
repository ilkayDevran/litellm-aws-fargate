#!/usr/bin/env bash
#
# Register a Bedrock or Vertex AI model in LiteLLM via the /model/new API.
# Models persist in RDS (STORE_MODEL_IN_DB=True), survive task restarts.
#
# Examples:
#   ./add-bedrock-model.sh
#   PROVIDER=vertex ./add-bedrock-model.sh
#
# For a fully custom payload, just edit the PAYLOAD heredoc below.

set -euo pipefail

PROVIDER="${PROVIDER:-bedrock}"
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

case "${PROVIDER}" in
  bedrock)
    MODEL_NAME="${MODEL_NAME:-claude-sonnet-bedrock}"
    BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-anthropic.claude-3-5-sonnet-20241022-v2:0}"
    BEDROCK_REGION="${BEDROCK_REGION:-${REGION}}"
    PAYLOAD=$(cat <<EOF
{
  "model_name": "${MODEL_NAME}",
  "litellm_params": {
    "model": "bedrock/${BEDROCK_MODEL_ID}",
    "aws_region_name": "${BEDROCK_REGION}"
  },
  "model_info": {
    "description": "AWS Bedrock ${BEDROCK_MODEL_ID} (IAM task role auth)"
  }
}
EOF
)
    ;;
  vertex)
    MODEL_NAME="${MODEL_NAME:-gemini-vertex}"
    VERTEX_MODEL="${VERTEX_MODEL:-gemini-1.5-pro}"
    VERTEX_PROJECT="${VERTEX_PROJECT:?set VERTEX_PROJECT=<gcp-project-id>}"
    VERTEX_LOCATION="${VERTEX_LOCATION:-us-central1}"
    PAYLOAD=$(cat <<EOF
{
  "model_name": "${MODEL_NAME}",
  "litellm_params": {
    "model": "vertex_ai/${VERTEX_MODEL}",
    "vertex_project": "${VERTEX_PROJECT}",
    "vertex_location": "${VERTEX_LOCATION}"
  },
  "model_info": {
    "description": "GCP Vertex AI ${VERTEX_MODEL} (SA JSON via Secrets Manager)"
  }
}
EOF
)
    ;;
  *)
    echo "Unknown PROVIDER='${PROVIDER}' (use 'bedrock' or 'vertex')" >&2
    exit 1
    ;;
esac

echo "▸ Registering '${MODEL_NAME}' (${PROVIDER}) at ${PROXY_URL}..."
RESPONSE="$(curl -sS -X POST "${PROXY_URL}/model/new" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")"

echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"
