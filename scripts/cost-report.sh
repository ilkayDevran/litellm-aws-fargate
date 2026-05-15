#!/usr/bin/env bash
#
# ÜCRETSIZ maliyet raporu — LiteLLM Enterprise'ın UI'da kilitlediği
# (/global/spend/report) model/key bazlı $ kırılımının OSS eşdeğeri.
#
#   ./scripts/cost-report.sh                  # son 7 gün
#   ./scripts/cost-report.sh 2026-05-01 2026-05-15
#
# Kaynak endpoint'ler (hepsi OSS-free):
#   /spend/logs/ui   per-request (anında, asıl kaynak) -> model+alias kırılımı
#   /global/spend/logs  günlük toplam
#
# Not: /key/info key-level sayacı asenkron gecikir; rapor per-request
# log'dan üretildiği için anlık ve doğrudur.

set -euo pipefail

REGION="${AWS_REGION:-eu-central-1}"
STACK_NAME="${STACK_NAME:-litellm-proxy}"

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

END_DATE="${2:-$(date -u +%Y-%m-%d)}"
if [[ -n "${1:-}" ]]; then
  START_DATE="$1"
else
  START_DATE="$(date -u -v-7d +%Y-%m-%d 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%d)"
fi

echo "▸ Maliyet raporu: ${START_DATE} → ${END_DATE}  (${PROXY_URL})"
echo

PROXY_URL="${PROXY_URL}" MASTER_KEY="${MASTER_KEY}" \
START_DATE="${START_DATE}" END_DATE="${END_DATE}" python3 - <<'PY'
import os, json, urllib.request, urllib.parse, collections

BASE = os.environ["PROXY_URL"]
MK = os.environ["MASTER_KEY"]
START = os.environ["START_DATE"]
END = os.environ["END_DATE"]


def get(path):
    req = urllib.request.Request(BASE + path,
                                 headers={"Authorization": "Bearer " + MK})
    return json.load(urllib.request.urlopen(req))


# --- per-request log (paginated) ---
rows = []
page = 1
qs_base = urllib.parse.urlencode({
    "start_date": f"{START} 00:00:00",
    "end_date": f"{END} 23:59:59",
    "page_size": 100,
    "sort_by": "startTime",
    "sort_order": "desc",
})
while True:
    d = get(f"/spend/logs/ui?{qs_base}&page={page}")
    batch = d.get("data", d) if isinstance(d, dict) else d
    if not batch:
        break
    rows.extend(batch)
    total_pages = d.get("total_pages", 1) if isinstance(d, dict) else 1
    if page >= total_pages:
        break
    page += 1

by_model = collections.defaultdict(lambda: [0.0, 0, 0])   # spend, reqs, tokens
by_alias = collections.defaultdict(lambda: [0.0, 0, 0])
total_spend = 0.0
total_reqs = 0

for r in rows:
    model = r.get("model")
    if not model:
        continue
    spend = float(r.get("spend") or 0)
    toks = int(r.get("total_tokens") or 0)
    alias = (r.get("metadata") or {}).get("user_api_key_alias") or "(alias yok)"
    by_model[model][0] += spend
    by_model[model][1] += 1
    by_model[model][2] += toks
    by_alias[alias][0] += spend
    by_alias[alias][1] += 1
    by_alias[alias][2] += toks
    total_spend += spend
    total_reqs += 1


def table(title, agg):
    print(f"=== {title} ===")
    print(f"{'isim':<52} {'spend $':>12} {'req':>6} {'token':>10}")
    print("-" * 84)
    for name, (sp, rq, tk) in sorted(agg.items(), key=lambda x: -x[1][0]):
        print(f"{name:<52} {sp:>12.6f} {rq:>6} {tk:>10}")
    print()


table("MODEL BAZLI", by_model)
table("KEY (ALIAS) BAZLI", by_alias)

print(f"TOPLAM: ${total_spend:.6f}  |  {total_reqs} faturalanabilir request")
print()

# --- günlük aggregate (cross-check) ---
print("=== GÜNLÜK TOPLAM (/global/spend/logs) ===")
try:
    daily = get("/global/spend/logs")
    for x in daily:
        if START <= x.get("date", "") <= END:
            print(f"  {x['date']}: ${float(x.get('spend') or 0):.6f}")
except Exception as e:
    print(f"  (alınamadı: {e})")
PY
