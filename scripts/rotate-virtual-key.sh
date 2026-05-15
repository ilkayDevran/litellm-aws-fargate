#!/usr/bin/env bash
#
# ON-DEMAND virtual key reset/rotation by alias. ELLE çalıştırılır.
#
#   ./scripts/rotate-virtual-key.sh <key_alias>
#
# Ne yapar:
#   1. /key/list ile alias'a ait mevcut key parametrelerini okur
#   2. (kanıtlanmış asenkron spend-log flush için) birkaç sn bekler
#   3. Eski key'i siler (alias ile) — secret artık geçersiz
#   4. AYNI alias + AYNI models/budget/limit ile YENİ key üretir
#   5. Yeni sk- key'i yazdırır
#
# Neden bu pattern: LiteLLM'in in-place /key/regenerate'i Enterprise-gated.
# Bu OSS-free eşdeğeri. Alias unique olduğu için sıra "önce sil, sonra üret".
#
# LOG KAYBI YOK: spend log'ları LiteLLM_SpendLogs'ta request bazında (alias
# dahil) tutulur; /key/delete bu satırları SİLMEZ. Eski + yeni key aynı
# alias'ı taşıdığı için alias-bazlı maliyet raporu kesintisiz birikir.
# Per-key sayaç yeni key'de $0'dan başlar (alias geçmişi DB'de korunur).
#
# Tek dikkat: spend-log yazımı asenkron. Bir request'in HEMEN ardından
# rotate edersen o son request'in log'u henüz flush olmadıysa kaybolabilir;
# script bu yüzden silmeden önce FLUSH_WAIT (default 8 sn) bekler.

set -euo pipefail

ALIAS="${1:-${KEY_ALIAS:?kullanım: rotate-virtual-key.sh <key_alias>}}"
REGION="${AWS_REGION:-eu-central-1}"
STACK_NAME="${STACK_NAME:-litellm-proxy}"
FLUSH_WAIT="${FLUSH_WAIT:-8}"

if [[ -z "${PROXY_URL:-}" ]]; then
  : "${DOMAIN_NAME:=litellm.example.com}"
  PROXY_URL="https://${DOMAIN_NAME}"
fi

if [[ -z "${MASTER_KEY:-}" ]]; then
  MASTER_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "${STACK_NAME}/master-key" \
    --region "${REGION}" \
    --query SecretString --output text)"
fi

AUTH="Authorization: Bearer ${MASTER_KEY}"
JSON="Content-Type: application/json"

echo "▸ '${ALIAS}' alias'ının mevcut parametreleri okunuyor..."
PARAMS_JSON="$(curl -sS "${PROXY_URL}/key/list?key_alias=${ALIAS}&return_full_object=true&size=10" \
  -H "${AUTH}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = d.get('keys', []) if isinstance(d, dict) else d
for k in keys:
    info = k.get('key') if isinstance(k, dict) and isinstance(k.get('key'), dict) else k
    if info.get('key_alias') == '${ALIAS}':
        out = {
            'models': info.get('models') or [],
            'max_budget': info.get('max_budget'),
            'budget_duration': info.get('budget_duration'),
            'rpm_limit': info.get('rpm_limit'),
            'tpm_limit': info.get('tpm_limit'),
            'team_id': info.get('team_id'),
        }
        print(json.dumps(out))
        break
else:
    sys.exit('ALIAS_NOT_FOUND')
")"

if [[ -z "${PARAMS_JSON}" || "${PARAMS_JSON}" == "ALIAS_NOT_FOUND" ]]; then
  echo "✗ '${ALIAS}' alias'ında key bulunamadı. /key/list ile kontrol et." >&2
  exit 1
fi

echo "  Bulunan parametreler: ${PARAMS_JSON}"
echo
echo "▸ Bu işlem '${ALIAS}' key'inin SECRET'ını değiştirir (eski sk- geçersiz olur)."
echo "  Spend log'ları KORUNUR. Devam? (yes/no)"
if [[ "${FORCE:-}" == "yes" || ! -t 0 ]]; then
  CONFIRM="yes"; echo "  (otomatik: yes)"
else
  read -r CONFIRM
fi
[[ "${CONFIRM}" == "yes" ]] || { echo "İptal edildi."; exit 0; }

echo "▸ Asenkron spend-log flush için ${FLUSH_WAIT} sn bekleniyor..."
sleep "${FLUSH_WAIT}"

echo "▸ Eski key siliniyor (alias: ${ALIAS})..."
curl -sS -X POST "${PROXY_URL}/key/delete" -H "${AUTH}" -H "${JSON}" \
  -d "{\"key_aliases\":[\"${ALIAS}\"]}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('  silindi:', d.get('deleted_keys', d))
"

echo "▸ Aynı alias + aynı parametrelerle yeni key üretiliyor..."
GEN_PAYLOAD="$(python3 -c "
import json
p = json.loads('''${PARAMS_JSON}''')
body = {'key_alias': '${ALIAS}', 'models': p['models']}
for f in ('max_budget', 'budget_duration', 'rpm_limit', 'tpm_limit'):
    if p.get(f) is not None:
        body[f] = p[f]
if p.get('team_id'):
    body['team_id'] = p['team_id']
print(json.dumps(body))
")"

NEW_KEY="$(curl -sS -X POST "${PROXY_URL}/key/generate" -H "${AUTH}" -H "${JSON}" \
  -d "${GEN_PAYLOAD}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'key' not in d:
    sys.exit('key üretilemedi: ' + json.dumps(d)[:300])
print(d['key'])
")"

cat <<EOF

✓ '${ALIAS}' key'i resetlendi.
  YENİ KEY: ${NEW_KEY}

Sırada:
  - Bu yeni key'i projendeki config/secret'a yapıştır (eski sk- artık 401 verir).
  - Geçmiş spend log'ları '${ALIAS}' alias'ıyla DB'de duruyor — kayıp yok.
  - Yeni key'in per-key sayacı \$0'dan başlar; alias-bazlı rapor kesintisiz.
EOF
