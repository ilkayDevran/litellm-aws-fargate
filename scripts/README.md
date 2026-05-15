# scripts/

Operasyonel script'lerin kullanım kılavuzu. Sıra deploy yaşam döngüsünü izler.

## Kurulum

Tüm script'ler ayarları ortam değişkenlerinden okur. Bir kez kaynakla:

```bash
cp .env.example .env.local        # ilk sefer; gerçek değerlerle doldur
set -a; source .env.local; set +a # her yeni shell'de
chmod +x scripts/*.sh             # ilk sefer
```

`.env.local` (gitignored) içindeki anahtarlar:

| Değişken | Kullanan | Açıklama |
|---|---|---|
| `DOMAIN_NAME` | tümü | Proxy URL'i bundan türer (`https://<DOMAIN_NAME>`) |
| `HOSTED_ZONE_ID`, `ALERT_EMAIL` | `deploy.sh` | Route 53 zone + CloudWatch alarm e-postası |
| `AWS_REGION` | tümü | Hedef bölge (script default'u `us-east-1` — kendi bölgeni set et) |
| `STACK_NAME` | tümü | CloudFormation stack adı (default `litellm-proxy`) |
| `ENABLE_WAF` | `deploy.sh` | Set'liyse prompt sorulmaz; boşsa interaktif sorulur |
| `HOST`, `TEST_MODEL` | `smoke-test.sh` | Doğrulama hedefi (DOMAIN_NAME'den ayrı okunur) |
| `MODELS` | `create-virtual-key.sh` | Key'in erişeceği public model adları |
| `MASTER_KEY`, `PROXY_URL` | helper'lar | Boş bırak — Secrets Manager'dan otomatik çözülür |

---

## deploy.sh — kurulum / güncelleme

```bash
./scripts/deploy.sh                    # interaktif: WAF? / build atla?
SKIP_BUILD=true ./scripts/deploy.sh    # sadece CFN (image'a dokunma)
```

Tek giriş noktası: ECR repo'sunu garanti eder, gerekirse image build+push eder,
CloudFormation stack'i deploy eder, yeni image varsa ECS'i yeni deployment'a zorlar.
İlk çalıştırmada DB/master/UI parolalarını üretip Secrets Manager'a yazar; sonraki
çalıştırmalarda oradan okur (idempotent). `litellm/config.yaml` veya `Dockerfile`
değiştiyse build çalıştır (prompt'a `N`); sadece infra değiştiyse `SKIP_BUILD=true`.

## smoke-test.sh — deploy sonrası doğrulama

```bash
./scripts/smoke-test.sh
```

5 kontrol: ECS revizyon/çalışan task, health endpoint, retention job, WAF sahte
isteği blokluyor mu, geçerli isteği geçiriyor mu. `HOST` ve `TEST_MODEL`
env'lerini okur (bunlar `.env.local`'da set edilmeli).

## create-virtual-key.sh — proje key'i üret

```bash
./scripts/create-virtual-key.sh <alias>
MODELS="model-a,model-b" MAX_BUDGET=20 ./scripts/create-virtual-key.sh proj-x
```

Belirtilen alias için kendi RPM/TPM/budget limitleriyle yeni bir `sk-` virtual key
üretir. `MODELS` gerçek public model adlarını içermeli (UI'da kayıtlı adlar).
Dönen key'i projenin secret'ına koy. IP/rate limit yok — kontrol key seviyesinde.

İsteğe bağlı env: `RPM_LIMIT` (60), `TPM_LIMIT` (100000), `MAX_BUDGET` (50),
`BUDGET_DURATION` (30d), `TEAM_ID`.

## add-bedrock-model.sh — model kaydet (UI alternatifi)

```bash
./scripts/add-bedrock-model.sh
PROVIDER=vertex VERTEX_PROJECT=<gcp-project> ./scripts/add-bedrock-model.sh
```

Model'i UI yerine CLI'dan kaydeder; kayıt RDS'te tutulur, task restart'ında kalıcı.
Bedrock için `MODEL_NAME`/`BEDROCK_MODEL_ID`/`BEDROCK_REGION`, Vertex için
`MODEL_NAME`/`VERTEX_MODEL`/`VERTEX_PROJECT`/`VERTEX_LOCATION` env'leriyle özelleştir.

## cost-report.sh — maliyet raporu

```bash
./scripts/cost-report.sh                       # son 7 gün
./scripts/cost-report.sh 2026-05-01 2026-05-31 # tarih aralığı
```

Model ve key (alias) bazında harcama dökümü + günlük toplam üretir. Veriyi
proxy'nin spend log'larından çeker (in-UI rapor Enterprise-gated; veri yine de
tam erişilebilir).

## rotate-virtual-key.sh — proje key'ini resetle

```bash
./scripts/rotate-virtual-key.sh <alias>
FORCE=yes ./scripts/rotate-virtual-key.sh <alias>   # onay sorma
```

Eski key'i siler, **aynı alias + aynı limitlerle** yeni key üretir, yeni `sk-`'yı
yazdırır. Geçmiş harcama log'ları alias ile korunur; alias-bazlı raporlama
kesintisiz. `FLUSH_WAIT` (default 8 sn) silmeden önce son log'ların yazılmasını
bekler. Geçici/geri-alınabilir devre dışı bırakma için bunun yerine
`POST /key/block` → `POST /key/unblock` kullan.

## rotate-master-key.sh — admin master key'i resetle

```bash
./scripts/rotate-master-key.sh
```

Master key'i değiştirir; onay için `yes` ister. ECS task'ı ~30-60 sn restart eder.
Virtual key'leri ve UI login'i etkilemez; helper script'ler yeni key'i Secrets
Manager'dan otomatik alır.

---

## Tipik akışlar

```bash
set -a; source .env.local; set +a

# İlk kurulum
./scripts/deploy.sh
./scripts/smoke-test.sh

# Sadece config/CFN değişikliği
SKIP_BUILD=true ./scripts/deploy.sh && ./scripts/smoke-test.sh

# Yeni proje onboard
./scripts/create-virtual-key.sh proj-x

# Aylık maliyet
./scripts/cost-report.sh 2026-05-01 2026-05-31

# Key sızıntısı
FORCE=yes ./scripts/rotate-virtual-key.sh proj-x
```
