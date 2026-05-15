# litellm-aws-fargate

**Production-grade LiteLLM AI gateway on AWS Fargate** — one CloudFormation stack:
multi-provider routing (Bedrock + Vertex), per-key cost tracking & budgets, WAF,
autoscaling, CloudWatch alarms. Infrastructure-as-code, template-ready.

![AWS](https://img.shields.io/badge/AWS-Fargate%20%7C%20RDS%20%7C%20ALB-FF9900?logo=amazonaws&logoColor=white)
![IaC](https://img.shields.io/badge/IaC-CloudFormation-blue)
![Python](https://img.shields.io/badge/scripts-bash%20%2B%20python3%20(stdlib)-3776AB?logo=python&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

```
Your apps (OpenAI-compatible SDK / HTTP)
        │  HTTPS, single sk- virtual key per project
        ▼
   ALB ──► ECS Fargate (LiteLLM)  ──►  AWS Bedrock (Claude)
                │                  └─►  GCP Vertex AI (Gemini)
                ▼
   RDS PostgreSQL  ── per-request spend, tokens, tags
   Admin UI at /ui ── models, keys, usage
```

One central proxy so every internal project routes LLM calls through a single
endpoint with **consolidated cost observability**, per-team budgets and key
auth — instead of fragmented direct-to-provider calls with no central spend view.

## Features

- **Single CloudFormation stack** — `deploy.sh` is the only entrypoint (build + push + CFN + rollout), idempotent, reuses the account default VPC.
- **Multi-provider** — AWS Bedrock (IAM task role, no keys) + GCP Vertex AI (SA JSON pasted in UI, encrypted at rest in RDS). Add models without touching infra.
- **Cost tracking / FinOps** — per-request spend in RDS, attributable per **virtual key**, **model**, and request **tags** / end-user. `cost-report.sh` gives a free model/key $ breakdown (the in-UI breakdown is LiteLLM-Enterprise-gated; data is fully captured regardless).
- **Auth** — LiteLLM virtual keys, each with its own RPM/TPM/budget. No IP allowlist (burst/Lambda traffic friendly); abuse is bounded per-key.
- **Optional WAF** (`ENABLE_WAF=true`) — AWS managed IP-reputation + known-bad-input rules plus a lightweight auth-format pre-filter at the edge. No rate-limit rule (per-key budgets handle abuse; auth is enforced by LiteLLM, not the WAF).
- **Autoscaling** — ECS Application Auto Scaling, Min 1 / Max 2, ALB request-per-task target tracking.
- **Observability** — 6 CloudWatch alarms (no healthy tasks, 5xx spike, ECS memory, RDS CPU, RDS storage, autoscaling-at-max) → SNS email.
- **Hardened ops** — HTTPS-only (HTTP→301), ACM cert via Route 53 DNS validation, secrets in Secrets Manager, stack-wide resource tagging, spend-log retention auto-purge, on-demand key rotation tooling.

## Architecture

| Component | Detail |
|---|---|
| **ECS Fargate** | LiteLLM proxy, 0.5 vCPU / 2 GB, 1 worker; autoscale 1→2 |
| **Application LB** | Internet-facing, HTTPS :443 (HTTP :80 → 301), ACM cert |
| **Route 53** | A-alias `litellm.<your-domain>` → ALB (hosted zone in same account) |
| **RDS PostgreSQL** | `db.t4g.micro` default, single-AZ, 20 GB gp3, 7-day backup, snapshot on delete |
| **Secrets Manager** | DB / master / UI passwords; optional GCP SA pattern |
| **IAM task role** | Bedrock `InvokeModel` (Converse + ResponseStream) |
| **WAF** *(optional)* | AWS managed IP-reputation + known-bad-input rules + edge auth-format pre-filter |
| **VPC** | Account default VPC auto-discovered (override via `VPC_ID`/`SUBNET_IDS`) |

Approx. cost: **~$45–60/month** depending on RDS instance class.

## Prerequisites

- AWS CLI v2 (`aws sts get-caller-identity` works)
- Docker (image build)
- A Route 53 hosted zone for your parent domain (same AWS account)
- IAM perms: CloudFormation, EC2/VPC, ECS, RDS, IAM, ELB, ACM, Route 53, ECR, Secrets Manager, CloudWatch, WAFv2, SNS

## Quick start

```bash
cp .env.example .env.local        # set DOMAIN_NAME, HOSTED_ZONE_ID, ALERT_EMAIL, AWS_REGION
set -a; source .env.local; set +a
chmod +x scripts/*.sh

./scripts/deploy.sh               # prompts: WAF? [Y/n]  build? [Y/n]
./scripts/smoke-test.sh           # post-deploy verification
```

First run generates DB/master/UI passwords into Secrets Manager; subsequent runs
reuse them (idempotent re-deploy). First deploy ~10–15 min (RDS + ACM validation).

## Scripts

All read config from env (`source .env.local` once). Details: [`scripts/README.md`](scripts/README.md).

| Script | When | What |
|---|---|---|
| `deploy.sh` | install / any change | sole entrypoint: build+push+CFN+rollout. `SKIP_BUILD=true` → CFN-only |
| `smoke-test.sh` | after every deploy | 5 checks: ECS rev/running, health, retention, WAF block/pass |
| `create-virtual-key.sh <alias>` | onboard a project | new `sk-` key with RPM/TPM/budget (`MODELS=...` to scope) |
| `add-bedrock-model.sh` | register a model via CLI | Bedrock or `PROVIDER=vertex` (UI also works; persisted in RDS) |
| `cost-report.sh [start] [end]` | cost review | free model/key $ breakdown + daily totals |
| `rotate-virtual-key.sh <alias>` | key leak / rotation | delete + re-create same alias; **spend logs preserved** |
| `rotate-master-key.sh` | admin key leak | rotate master key (~30–60 s ECS restart; virtual keys unaffected) |

## Adding models

**Bedrock** — no credentials (IAM task role). UI → Models → Add, or `./scripts/add-bedrock-model.sh`.

**Vertex** — UI → Models → Add → provider *Vertex AI* → set `vertex_project` / `vertex_location` → paste the full **service-account JSON** into `vertex_credentials` (stored encrypted in RDS). Scales without infra changes. An optional Secrets-Manager-backed pattern (CloudTrail-auditable) is documented in the CFN template comments.

## Calling the proxy

OpenAI-compatible — point any client at the proxy with a virtual key. Provider
(Bedrock/Vertex) is resolved server-side; your code only knows the public model name.

```python
import json, urllib.request
req = urllib.request.Request(
    "https://litellm.<your-domain>/v1/chat/completions",
    data=json.dumps({"model": "your-model",
                     "messages": [{"role": "user", "content": "ping"}],
                     "max_tokens": 50}).encode(),
    headers={"Authorization": "Bearer sk-...", "Content-Type": "application/json"},
)
print(json.load(urllib.request.urlopen(req))["choices"][0]["message"]["content"])
```

Zero-dependency drop-in provider + an annotated parameter reference (temperature,
thinking control, prompt caching, cost-attribution tags) live in
[`examples/`](examples/README.md).

## Cost reporting

Spend is captured per request in RDS (model, tokens, virtual key, tags, end-user).
The polished in-UI spend *report* is LiteLLM-Enterprise-gated, but the data is
fully available on the open-source build:

```bash
./scripts/cost-report.sh 2026-05-01 2026-05-31   # model + key $ breakdown, daily totals
```

Attribute cost per project/feature by passing `metadata.tags` / `user` on requests.

## Operations

- **Logs**: CloudWatch `/ecs/<stack>` log group
- **Config change**: edit `litellm/config.yaml` or `Dockerfile` → `./scripts/deploy.sh`
- **Infra-only change**: `SKIP_BUILD=true ./scripts/deploy.sh`
- **Temporarily disable a key**: `POST /key/block` → `POST /key/unblock` (reversible, free)

## Scale-up path

| Trigger | Action |
|---|---|
| Sustained high RPS | raise `MaxTaskCount` (autoscaling already on) |
| RDS CPU > 70% | bump `DB_INSTANCE_CLASS` (e.g. `db.t4g.medium`), re-deploy |
| Need HA | RDS `MultiAZ`, ECS desired ≥ 2 (subnets already span AZs) |
| Caching wanted | ElastiCache Redis + LiteLLM cache config |
| Full request tracing | Langfuse callback |
| Storage growth | `MaxAllocatedStorage` (RDS storage autoscaling) |

## Security

- **No secrets in the repo.** Per-deployment values (domain, account, email, GCP project IDs) live only in `.env.local` and `docs/` — both gitignored. `.gitignore` also covers `.env*`, `*.pem`, `*.key`, `gcp-sa*.json`.
- Runtime secrets (DB/master/UI passwords, Vertex SA JSON) are in AWS Secrets Manager / RDS-encrypted, never in code or env files.
- `.env.example` ships placeholders only.

## Deploy in another AWS account

This repo is a template:

1. Clone/fork.
2. Ensure a Route 53 hosted zone exists in the target account.
3. Create `.env.local` (`DOMAIN_NAME`, `HOSTED_ZONE_ID`, `ALERT_EMAIL`, `AWS_REGION`).
4. Configure AWS CLI for that account; in Bedrock console approve model access.
5. `./scripts/deploy.sh`

## Cleanup

```bash
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
aws ecr delete-repository --repository-name "$STACK_NAME" --force --region "$AWS_REGION"
```

RDS leaves a final snapshot (DeletionPolicy: Snapshot); Secrets Manager keeps a 30-day recovery window.

## License

MIT — see [LICENSE](LICENSE).
