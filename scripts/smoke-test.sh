#!/usr/bin/env bash
#
# Deploy sonrası end-to-end doğrulama. Her redeploy'dan sonra çalıştır:
#   ./scripts/smoke-test.sh
#
# Override env:
#   REGION       default eu-central-1
#   HOST         default https://litellm.example.com
#   TEST_MODEL   default your-vertex-model  (UI'da verdiğin public model adı)

set -u
REGION="${REGION:-eu-central-1}"
HOST="${HOST:-https://litellm.example.com}"
TEST_MODEL="${TEST_MODEL:-your-vertex-model}"
CLUSTER="${CLUSTER:-litellm-proxy-cluster}"
SERVICE="${SERVICE:-litellm-proxy-service}"
LOG_GROUP="${LOG_GROUP:-/ecs/litellm-proxy}"

body="{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}"

echo "=== 1) ECS servis durumu (rev + running count) ==="
aws ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].{desired:desiredCount,running:runningCount,taskdef:taskDefinition,rollout:deployments[0].rolloutState}' \
  --output json

echo
echo "=== 2) Health ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "$HOST/health/liveliness"

echo
echo "=== 3) Retention cleanup job log'da var mi (son 25 dk) ==="
aws logs tail "$LOG_GROUP" --since 25m --region "$REGION" --format short 2>/dev/null \
  | grep -i "retention\|spend\|cleanup\|purge" | tail -5
echo "(bossa: log 25dk'dan eski olabilir ya da key adi farkli)"

echo
echo "=== 4) WAF: sahte key (Bearer admin) -> 403 BEKLENIYOR ==="
c4=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$HOST/v1/chat/completions" \
  -H "Authorization: Bearer admin" -H "Content-Type: application/json" -d "$body")
echo "HTTP $c4  -> $([ "$c4" = "403" ] && echo 'WAF BLOKLADI (dogru)' || echo 'WAF tetiklenmedi — incele')"

echo
echo "=== 5) WAF: sk- formati -> 403 OLMAMALI ==="
c5=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$HOST/v1/chat/completions" \
  -H "Authorization: Bearer sk-format-test-not-real-key" -H "Content-Type: application/json" -d "$body")
echo "HTTP $c5  -> $([ "$c5" = "403" ] && echo 'PROBLEM: WAF gercek formati da bloklar!' || echo 'WAF gecirdi, LiteLLM auth devrede (dogru)')"

echo
echo "=== OZET ==="
echo "Check4 sahte key : $c4   (403 ideal — WAF blokladi)"
echo "Check5 sk- format: $c5   (401/400/200 ideal; 403 KOTU — WAF cok agresif)"
