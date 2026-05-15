#!/usr/bin/env bash
#
# ON-DEMAND master key rotation. Sızıntı şüphesi veya periyodik güvenlik için
# ELLE çalıştırılır — zamanlanmış otomasyon DEĞİL.
#
#   ./scripts/rotate-master-key.sh
#
# Ne yapar:
#   1. Yeni sk- master key üretir
#   2. Secrets Manager'daki litellm-proxy/master-key secret'ını günceller
#   3. ECS force-new-deployment (task yeni key'le restart, ~30-60 sn downtime)
#   4. Service stable olana kadar bekler, yeni key'i yazdırır
#
# ETKİLEMEZ: virtual key'ler (uygulamaların), UI login (UI password ayrı).
# ETKİLER:   master key ile yapılan admin işlemleri — helper script'ler
#            Secrets Manager'dan dinamik okuduğu için otomatik adapte olur.

set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
STACK_NAME="${STACK_NAME:-litellm-proxy}"
SECRET_ID="${STACK_NAME}/master-key"
CLUSTER="${STACK_NAME}-cluster"
SERVICE="${STACK_NAME}-service"

echo "▸ Bu işlem master key'i değiştirir + ECS task'ı ~30-60 sn restart eder."
echo "  Virtual key'ler ve UI ETKİLENMEZ. Devam? (yes/no)"
read -r CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { echo "İptal edildi."; exit 0; }

NEW_KEY="sk-$(openssl rand -hex 24)"

echo "▸ Secrets Manager güncelleniyor (${SECRET_ID})..."
aws secretsmanager put-secret-value \
  --secret-id "${SECRET_ID}" \
  --secret-string "${NEW_KEY}" \
  --region "${REGION}" \
  --query 'VersionId' --output text >/dev/null

echo "▸ ECS force-new-deployment (task yeni key'i pick edecek)..."
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --force-new-deployment \
  --region "${REGION}" \
  --query 'service.deployments[0].{Status:status,Rollout:rolloutState}' \
  --output table

echo "▸ Service stable bekleniyor (birkaç dk)..."
aws ecs wait services-stable \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}" \
  --region "${REGION}" && echo "✓ Yeni master key aktif"

cat <<EOF

✓ Master key rotate edildi.
  Yeni key Secrets Manager'da: ${SECRET_ID}
  Değer:  ${NEW_KEY}

Notlar:
  - Helper script'ler (create-virtual-key/add-bedrock-model) yeni key'i
    Secrets Manager'dan otomatik okur — bir şey yapman gerekmez.
  - Master key'i elle bir yere yazdıysan (CI secret, kişisel not) güncelle.
  - Eski key artık geçersiz. Virtual key'ler etkilenmedi, çalışmaya devam ediyor.
EOF
