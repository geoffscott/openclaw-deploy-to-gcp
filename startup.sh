#!/bin/bash
# startup.sh — OpenClaw provisioning script (runs on GCP instance boot)
# This script is idempotent and safe to run on every boot.
set -euo pipefail

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/${OPENCLAW_USER}"
SENTINEL_FILE="/var/lib/openclaw/.provisioned"
LOG_TAG="openclaw-startup"
NODE_MAJOR=22

log() { logger -t "${LOG_TAG}" "$*"; echo "[${LOG_TAG}] $*"; }

# ─── Already provisioned? Just ensure the service is running ─────────────────
if [ -f "${SENTINEL_FILE}" ]; then
  log "Already provisioned. Ensuring service is running."
  systemctl start openclaw-gateway.service 2>/dev/null || true
  exit 0
fi

log "Starting OpenClaw provisioning…"

# ─── 1. Create dedicated user ───────────────────────────────────────────────
if ! id "${OPENCLAW_USER}" &>/dev/null; then
  log "Creating user ${OPENCLAW_USER}…"
  useradd --system --create-home --shell /bin/bash "${OPENCLAW_USER}"
fi

# ─── 2. Install Node.js 22 from NodeSource ──────────────────────────────────
if ! command -v node &>/dev/null || [ "$(node --version | cut -d. -f1 | tr -d v)" -lt "${NODE_MAJOR}" ]; then
  log "Installing Node.js ${NODE_MAJOR}…"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg git
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  apt-get install -y -qq nodejs
fi
log "Node.js version: $(node --version)"

# ─── 3. Install OpenClaw globally ───────────────────────────────────────────
if ! command -v openclaw &>/dev/null; then
  log "Installing openclaw…"
  npm install -g openclaw@latest
fi

OPENCLAW_BIN="$(which openclaw)"
log "openclaw binary: ${OPENCLAW_BIN}"

# ─── 4. Create systemd service ──────────────────────────────────────────────
log "Creating systemd service…"
cat > /etc/systemd/system/openclaw-gateway.service <<UNIT
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OPENCLAW_USER}
Group=${OPENCLAW_USER}
WorkingDirectory=${OPENCLAW_HOME}
ExecStart=${OPENCLAW_BIN} gateway --port 18789 --verbose
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

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
