#!/bin/bash
# Claude Code session-start hook — installs gcloud and authenticates with GCP.
# Only runs in remote (Claude.ai cloud) environments.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

GCLOUD_INSTALL_DIR="${HOME}/.local/gcloud"
GCLOUD_BIN="${GCLOUD_INSTALL_DIR}/google-cloud-sdk/bin/gcloud"

# ── Install gcloud if missing ─────────────────────────────────────────────────
if ! command -v gcloud &>/dev/null && [ ! -x "${GCLOUD_BIN}" ]; then
  echo "▶ Installing Google Cloud SDK (first run only — will be cached)…"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  curl -sSL https://sdk.cloud.google.com \
    | bash -s -- --disable-prompts --install-dir="${GCLOUD_INSTALL_DIR}"
  echo "✓ gcloud installed to ${GCLOUD_INSTALL_DIR}"
fi

# Ensure gcloud is on PATH for this session
if [ ! -x "$(command -v gcloud 2>/dev/null)" ] && [ -x "${GCLOUD_BIN}" ]; then
  export PATH="${GCLOUD_INSTALL_DIR}/google-cloud-sdk/bin:${PATH}"
  echo "export PATH=\"${GCLOUD_INSTALL_DIR}/google-cloud-sdk/bin:\${PATH}\"" >> "${CLAUDE_ENV_FILE}"
fi

# ── Authenticate via service account key ─────────────────────────────────────
# Requires GCP_SERVICE_ACCOUNT_KEY env var: the service account JSON key,
# base64-encoded. Generate it with:
#   base64 -w 0 my-key.json
# Then store it as a secret in your Claude Code environment settings.
if [ -n "${GCP_SERVICE_ACCOUNT_KEY:-}" ]; then
  KEY_FILE="$(mktemp /tmp/gcp-key-XXXXXX.json)"
  trap 'rm -f "${KEY_FILE}"' EXIT

  # Decode base64 → JSON key file
  echo "${GCP_SERVICE_ACCOUNT_KEY}" | base64 -d > "${KEY_FILE}"

  gcloud auth activate-service-account --key-file="${KEY_FILE}" --quiet
  echo "✓ Authenticated with GCP service account"
else
  echo "⚠  GCP_SERVICE_ACCOUNT_KEY not set — gcloud commands will require manual auth"
fi

# ── Set default project ───────────────────────────────────────────────────────
# Requires GCP_PROJECT_ID env var: your GCP project ID (e.g. my-project-123)
if [ -n "${GCP_PROJECT_ID:-}" ]; then
  gcloud config set project "${GCP_PROJECT_ID}" --quiet
  echo "✓ Default project set to ${GCP_PROJECT_ID}"
else
  echo "⚠  GCP_PROJECT_ID not set — pass --project to gcloud commands or set this variable"
fi
