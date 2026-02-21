#!/bin/bash
# startup.sh — OpenClaw provisioning script (runs on GCP instance boot)
# This script is idempotent and safe to run on every boot.
set -euo pipefail

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
SENTINEL_FILE="/var/lib/openclaw/.provisioned"
LOG_TAG="openclaw-startup"
NODE_MAJOR=22
SECRETS_ENV="/run/openclaw/env"
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

log() { logger -t "${LOG_TAG}" "$*"; echo "[${LOG_TAG}] $*"; }

# ─── Fetch secrets from Secret Manager (runs every boot) ────────────────────
# Every secret in the project becomes an environment variable:
#   Secret name "ANTHROPIC_API_KEY" with value "sk-ant-..." → ANTHROPIC_API_KEY=sk-ant-...
# This project should be dedicated to this deployment — all secrets are loaded.
fetch_secrets() {
  log "Fetching secrets from Secret Manager…"

  mkdir -p /run/openclaw
  chmod 700 /run/openclaw

  # Get project ID from metadata server
  local project_id
  project_id="$(curl -sf -H "${METADATA_HEADER}" \
    "${METADATA_URL}/project/project-id" 2>/dev/null)" || {
    log "Could not reach metadata server — skipping secret fetch."
    return 1
  }

  # Get access token from metadata server (requires VM service account)
  local token
  token="$(curl -sf -H "${METADATA_HEADER}" \
    "${METADATA_URL}/instance/service-accounts/default/token" 2>/dev/null \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')" || {
    log "No VM service account — skipping secret fetch."
    return 1
  }

  if [[ -z "${token}" ]]; then
    log "Empty access token — skipping secret fetch."
    return 1
  fi

  local sm_base="https://secretmanager.googleapis.com/v1/projects/${project_id}"

  # List all secrets in the project
  local list_response
  list_response="$(curl -sf \
    -H "Authorization: Bearer ${token}" \
    "${sm_base}/secrets" 2>/dev/null)" || {
    log "Could not list secrets (API may not be enabled or no secrets exist)."
    return 1
  }

  # Extract secret names from JSON (projects/PROJECT/secrets/NAME → NAME)
  local secret_names
  if command -v jq &>/dev/null; then
    secret_names="$(echo "${list_response}" \
      | jq -r '.secrets[]?.name // empty' 2>/dev/null \
      | sed 's|.*/||')"
  else
    secret_names="$(echo "${list_response}" \
      | grep -o '"name" *: *"projects/[^"]*/secrets/[^"]*"' \
      | sed 's|.*secrets/||;s|"$||')"
  fi

  if [[ -z "${secret_names}" ]]; then
    log "No secrets found in project — skipping."
    return 1
  fi

  # Fetch each secret's latest version and assemble the env file
  local tmp_env="${SECRETS_ENV}.tmp"
  : > "${tmp_env}"
  local count=0

  while IFS= read -r secret_name; do
    local response
    response="$(curl -sf \
      -H "Authorization: Bearer ${token}" \
      "${sm_base}/secrets/${secret_name}/versions/latest:access" 2>/dev/null)" || {
      log "  Skipping '${secret_name}' (no accessible version)."
      continue
    }

    local payload
    if command -v jq &>/dev/null; then
      payload="$(echo "${response}" | jq -r '.payload.data // empty' 2>/dev/null)"
    else
      payload="$(echo "${response}" | sed -n 's/.*"data" *: *"\([^"]*\)".*/\1/p')"
    fi

    if [[ -n "${payload}" ]]; then
      local value
      value="$(echo "${payload}" | base64 -d)"
      # Skip placeholder values — DISABLED/REPLACE_ME secrets should not be set
      if [[ "${value}" == "DISABLED" || "${value}" == "REPLACE_ME" ]]; then
        continue
      fi
      echo "${secret_name}=${value}" >> "${tmp_env}"
      count=$((count + 1))
    fi
  done <<< "${secret_names}"

  # Atomic replace
  mv "${tmp_env}" "${SECRETS_ENV}"
  chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${SECRETS_ENV}"
  chmod 600 "${SECRETS_ENV}"

  log "Loaded ${count} secret(s) from Secret Manager."
  return 0
}

# ─── Protect credential paths ─────────────────────────────────────────────
# Secrets are already protected:
#   • /run/openclaw/env  — tmpfs (RAM only), loaded from Secret Manager
#   • ~/.openclaw/.env   — symlinked to /dev/null
# The credentials directory is NOT mounted on tmpfs because OpenClaw stores
# device tokens there; wiping them on reboot breaks Web UI reconnection.
protect_credential_paths() {
  # Ensure the openclaw state dir exists
  local state_dir="${OPENCLAW_HOME}/.openclaw"
  mkdir -p "${state_dir}"
  chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${state_dir}"

  # Ensure credentials dir exists with restricted permissions
  local cred_dir="${state_dir}/credentials"
  mkdir -p "${cred_dir}"
  chmod 700 "${cred_dir}"

  # Unmount stale tmpfs bind-mount from previous versions if present
  if mountpoint -q "${cred_dir}" 2>/dev/null; then
    umount "${cred_dir}" 2>/dev/null || true
    log "Removed tmpfs bind-mount from ${cred_dir} (device tokens now persist)"
  fi

  # Prevent .env files from being written to persistent disk
  local dot_env="${state_dir}/.env"
  if [[ ! -L "${dot_env}" ]]; then
    rm -f "${dot_env}"
    ln -sf /dev/null "${dot_env}"
    log "Symlinked ${dot_env} → /dev/null"
  fi

  chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${state_dir}"
}

# ─── Install the secret-fetch script (for systemd ExecStartPre) ─────────────
install_fetch_script() {
  cat > /usr/local/bin/fetch-openclaw-secrets <<'FETCHSCRIPT'
#!/bin/bash
# Enumerates all secrets in the GCP project and writes them as NAME=VALUE
# lines to /run/openclaw/env. Called by systemd ExecStartPre before each
# gateway start. This project should be dedicated to this deployment.
set -euo pipefail

SECRETS_ENV="/run/openclaw/env"
METADATA_URL="http://metadata.google.internal/computeMetadata/v1"
METADATA_HEADER="Metadata-Flavor: Google"

mkdir -p /run/openclaw
chmod 700 /run/openclaw

PROJECT_ID="$(curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/project/project-id" 2>/dev/null)" || exit 0
TOKEN="$(curl -sf -H "${METADATA_HEADER}" "${METADATA_URL}/instance/service-accounts/default/token" 2>/dev/null \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')" || exit 0
[[ -z "${TOKEN}" ]] && exit 0

SM_BASE="https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}"

# List all secrets in the project
LIST="$(curl -sf -H "Authorization: Bearer ${TOKEN}" "${SM_BASE}/secrets" 2>/dev/null)" || exit 0
if command -v jq &>/dev/null; then
  NAMES="$(echo "${LIST}" | jq -r '.secrets[]?.name // empty' 2>/dev/null | sed 's|.*/||')"
else
  NAMES="$(echo "${LIST}" | grep -o '"name" *: *"projects/[^"]*/secrets/[^"]*"' \
    | sed 's|.*secrets/||;s|"$||')"
fi
[[ -z "${NAMES}" ]] && exit 0

# Fetch each secret's latest version
TMP="${SECRETS_ENV}.tmp"
: > "${TMP}"

while IFS= read -r SECRET_NAME; do
  RESP="$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
    "${SM_BASE}/secrets/${SECRET_NAME}/versions/latest:access" 2>/dev/null)" || continue
  if command -v jq &>/dev/null; then
    PAYLOAD="$(echo "${RESP}" | jq -r '.payload.data // empty' 2>/dev/null)"
  else
    PAYLOAD="$(echo "${RESP}" | sed -n 's/.*"data" *: *"\([^"]*\)".*/\1/p')"
  fi
  [[ -z "${PAYLOAD}" ]] && continue
  VALUE="$(echo "${PAYLOAD}" | base64 -d)"
  # Skip placeholder values — DISABLED/REPLACE_ME secrets should not be set
  [[ "${VALUE}" == "DISABLED" || "${VALUE}" == "REPLACE_ME" ]] && continue
  echo "${SECRET_NAME}=${VALUE}" >> "${TMP}"
done <<< "${NAMES}"

mv "${TMP}" "${SECRETS_ENV}"
chown openclaw:openclaw "${SECRETS_ENV}"
chmod 600 "${SECRETS_ENV}"
FETCHSCRIPT
  chmod 755 /usr/local/bin/fetch-openclaw-secrets
}

# ─── Try to fetch secrets on every boot ──────────────────────────────────────
# Ensure the user exists first (needed for chown in fetch_secrets)
if ! id "${OPENCLAW_USER}" &>/dev/null; then
  useradd --system --create-home --shell /bin/bash "${OPENCLAW_USER}"
fi

fetch_secrets || true
protect_credential_paths

# ─── Already provisioned? Just ensure the service is running ─────────────────
if [ -f "${SENTINEL_FILE}" ]; then
  log "Already provisioned. Ensuring service is running."

  # Always update the fetch-secrets helper so fixes propagate on reboot
  install_fetch_script

  # Self-repair: ensure the service unit has the correct ExecStart with --token
  UNIT_FILE="/etc/systemd/system/openclaw-gateway.service"
  NEEDS_RELOAD=false

  if [ -f "${UNIT_FILE}" ]; then
    # Add --allow-unconfigured if missing
    if ! grep -q -- '--allow-unconfigured' "${UNIT_FILE}"; then
      log "Updating service unit: adding --allow-unconfigured flag."
      sed -i 's|gateway --port 18789 --verbose|gateway --port 18789 --verbose --allow-unconfigured|' "${UNIT_FILE}"
      NEEDS_RELOAD=true
    fi

    # Add --token via shell wrapper if missing (critical for Web UI auth)
    if ! grep -q -- '--token' "${UNIT_FILE}"; then
      log "Updating service unit: adding --token flag for gateway auth."
      OPENCLAW_BIN="$(which openclaw 2>/dev/null || echo /usr/bin/openclaw)"
      sed -i "s|^ExecStart=.*|ExecStart=/bin/sh -c 'exec ${OPENCLAW_BIN} gateway --port 18789 --verbose --allow-unconfigured \${OPENCLAW_GATEWAY_TOKEN:+--token \"\${OPENCLAW_GATEWAY_TOKEN}\"}'|" "${UNIT_FILE}"
      NEEDS_RELOAD=true
    fi

    if ! grep -q 'StartLimitBurst' "${UNIT_FILE}"; then
      sed -i '/^Wants=network-online.target$/a StartLimitIntervalSec=300\nStartLimitBurst=5' "${UNIT_FILE}"
      NEEDS_RELOAD=true
    fi
  fi

  if [ "${NEEDS_RELOAD}" = true ]; then
    systemctl daemon-reload
  fi
  # Always restart so ExecStartPre re-fetches secrets with the updated helper
  systemctl restart openclaw-gateway.service 2>/dev/null || true

  exit 0
fi

log "Starting OpenClaw provisioning…"

# ─── 1. Install Node.js 22 from NodeSource ──────────────────────────────────
if ! command -v node &>/dev/null || [ "$(node --version | cut -d. -f1 | tr -d v)" -lt "${NODE_MAJOR}" ]; then
  log "Installing Node.js ${NODE_MAJOR}…"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg git jq
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
fi
log "Node.js version: $(node --version)"

# ─── 2. Install OpenClaw globally ───────────────────────────────────────────
if ! command -v openclaw &>/dev/null; then
  log "Installing openclaw…"
  npm install -g openclaw@latest
fi

OPENCLAW_BIN="$(which openclaw)"
log "openclaw binary: ${OPENCLAW_BIN}"

# ─── 3. Install the fetch-secrets helper ─────────────────────────────────────
install_fetch_script
log "Installed /usr/local/bin/fetch-openclaw-secrets"

# ─── 4. Create systemd service ──────────────────────────────────────────────
log "Creating systemd service…"
cat > /etc/systemd/system/openclaw-gateway.service <<UNIT
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=${OPENCLAW_USER}
Group=${OPENCLAW_USER}
WorkingDirectory=${OPENCLAW_HOME}

# Fetch fresh secrets from Secret Manager before each start
ExecStartPre=+/usr/local/bin/fetch-openclaw-secrets

# Load secrets from tmpfs (- prefix: don't fail if file is missing)
EnvironmentFile=-${SECRETS_ENV}

ExecStart=/bin/sh -c 'exec ${OPENCLAW_BIN} gateway --port 18789 --verbose --allow-unconfigured \${OPENCLAW_GATEWAY_TOKEN:+--token "\${OPENCLAW_GATEWAY_TOKEN}"}'
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

# Prevent OpenClaw from writing secrets to persistent disk
Environment=OPENCLAW_STATE_DIR=${OPENCLAW_HOME}/.openclaw

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable openclaw-gateway.service
systemctl start openclaw-gateway.service

# ─── 5. Mark as provisioned ─────────────────────────────────────────────────
mkdir -p /var/lib/openclaw
touch "${SENTINEL_FILE}"

log "OpenClaw provisioning complete."
