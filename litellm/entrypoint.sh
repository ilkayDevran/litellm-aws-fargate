#!/usr/bin/env bash
set -euo pipefail

: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${DB_USER:?DB_USER not set}"
: "${DB_PASSWORD:?DB_PASSWORD not set}"

export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Per-project GCP SA JSONs come in as GCP_SA_* env vars. Each Vertex model in
# LiteLLM references its own via litellm_params.vertex_credentials: os.environ/GCP_SA_<NAME>.
# No file writes needed.

exec litellm "$@"
