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
  echo "▶ Installing Google Cloud SDK…"
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1

  # Download from storage.googleapis.com instead of sdk.cloud.google.com,
  # which is blocked by the Claude Code egress proxy.
  # Discover the latest linux-x86_64 version from the GCS release bucket.
  # The bucket lists objects alphabetically and may have thousands of entries,
  # so we query with a high-version prefix to stay on the first page.
  GCLOUD_VERSION=""
  for _prefix in 9 8 7 6 5 4; do
    GCLOUD_VERSION=$(
      curl -sSL "https://storage.googleapis.com/storage/v1/b/cloud-sdk-release/o?prefix=google-cloud-cli-${_prefix}&maxResults=1000" \
        | python3 -c "
import json, sys, re
items = json.load(sys.stdin).get('items', [])
versions = set()
for i in items:
    m = re.search(r'google-cloud-cli-(\d+\.\d+\.\d+)-linux-x86_64\.tar\.gz', i['name'])
    if m:
        versions.add(m.group(1))
if versions:
    print(sorted(versions, key=lambda v: list(map(int, v.split('.'))), reverse=True)[0])
" 2>/dev/null
    ) && [ -n "${GCLOUD_VERSION}" ] && break
  done
  if [ -z "${GCLOUD_VERSION}" ]; then
    echo "✗ Failed to discover gcloud version" >&2
    exit 1
  fi

  TARBALL="google-cloud-cli-${GCLOUD_VERSION}-linux-x86_64.tar.gz"
  TARBALL_URL="https://storage.googleapis.com/cloud-sdk-release/${TARBALL}"

  mkdir -p "${GCLOUD_INSTALL_DIR}"
  curl -sSL "${TARBALL_URL}" -o "/tmp/${TARBALL}"
  tar -xzf "/tmp/${TARBALL}" -C "${GCLOUD_INSTALL_DIR}"
  rm -f "/tmp/${TARBALL}"

  # Skip running install.sh — it tries to reach dl.google.com (also blocked).
  # The extracted tarball already contains a working gcloud binary; PATH is
  # managed in the next section via CLAUDE_ENV_FILE.
  echo "✓ gcloud ${GCLOUD_VERSION} installed to ${GCLOUD_INSTALL_DIR}"
fi

# Ensure gcloud is on PATH for this session
if [ ! -x "$(command -v gcloud 2>/dev/null)" ] && [ -x "${GCLOUD_BIN}" ]; then
  export PATH="${GCLOUD_INSTALL_DIR}/google-cloud-sdk/bin:${PATH}"
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export PATH=\"${GCLOUD_INSTALL_DIR}/google-cloud-sdk/bin:\${PATH}\"" >> "${CLAUDE_ENV_FILE}"
  fi
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
