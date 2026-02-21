#!/bin/bash
# deploy.sh — Deploy an IAP-only VPS on Google Cloud with OpenClaw pre-installed
# Usage: bash deploy.sh [--project PROJECT_ID] [--zone ZONE] [--name INSTANCE_NAME]
#                       [--machine-type MACHINE_TYPE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────
INSTANCE_NAME="${INSTANCE_NAME:-iap-vps}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"
IMAGE_FAMILY="${IMAGE_FAMILY:-debian-12}"
IMAGE_PROJECT="${IMAGE_PROJECT:-debian-cloud}"
NETWORK="${NETWORK:-default}"
FIREWALL_RULE_NAME="${FIREWALL_RULE_NAME:-allow-iap-ssh}"
BOOT_DISK_TYPE="${BOOT_DISK_TYPE:-pd-ssd}"
BOOT_DISK_SIZE="${BOOT_DISK_SIZE:-20GB}"

# IAP's published IP range for TCP forwarding (SSH tunnelling)
IAP_CIDR="35.235.240.0/20"

# ─── Parse flags ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT_ID="$2";   shift 2 ;;
    --zone)          ZONE="$2";         shift 2 ;;
    --name)          INSTANCE_NAME="$2"; shift 2 ;;
    --machine-type)  MACHINE_TYPE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ─── Resolve project ─────────────────────────────────────────────────────────
if [[ -z "${PROJECT_ID:-}" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
fi

if [[ -z "${PROJECT_ID:-}" ]]; then
  echo "ERROR: No project set. Run 'gcloud config set project PROJECT_ID' or pass --project."
  exit 1
fi

REGION="${ZONE%-*}"   # strip zone suffix, e.g. us-central1-a → us-central1
VM_SA_NAME="${INSTANCE_NAME}-vm-sa"
VM_SA_EMAIL="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ─── Pre-flight: verify deployer permissions ─────────────────────────────────
check_deployer_permissions() {
  local deployer_email
  deployer_email="$(gcloud config get-value account 2>/dev/null)"

  echo "▶ Checking deployer permissions…"
  echo "  Account: ${deployer_email}"

  # Probe each required permission with a lightweight read-only gcloud command.
  # Uses --quiet to prevent interactive prompts and timeout to prevent hangs.
  local missing_roles=()

  # roles/compute.admin — can list instances
  if ! timeout 15 gcloud compute instances list \
       --project="${PROJECT_ID}" --limit=1 --quiet &>/dev/null; then
    missing_roles+=("roles/compute.admin")
  fi

  # roles/iam.serviceAccountAdmin — can list service accounts
  if ! timeout 15 gcloud iam service-accounts list \
       --project="${PROJECT_ID}" --limit=1 --quiet &>/dev/null; then
    missing_roles+=("roles/iam.serviceAccountAdmin")
  fi

  # roles/secretmanager.admin — can list secrets
  if ! timeout 15 gcloud secrets list \
       --project="${PROJECT_ID}" --limit=1 --quiet &>/dev/null; then
    missing_roles+=("roles/secretmanager.admin")
  fi

  # roles/iam.securityAdmin — can list IAM roles
  if ! timeout 15 gcloud iam roles list \
       --project="${PROJECT_ID}" --limit=1 --quiet &>/dev/null; then
    missing_roles+=("roles/iam.securityAdmin")
  fi

  # roles/serviceusage.serviceUsageAdmin — can list services
  if ! timeout 15 gcloud services list \
       --project="${PROJECT_ID}" --limit=1 --quiet &>/dev/null; then
    missing_roles+=("roles/serviceusage.serviceUsageAdmin")
  fi

  if [[ ${#missing_roles[@]} -eq 0 ]]; then
    echo "  ✓ All required permissions verified"
    return 0
  fi

  echo ""
  echo "  ✗ Missing ${#missing_roles[@]} required role(s):"
  for role in "${missing_roles[@]}"; do
    echo "      • ${role}"
  done
  echo ""
  echo "  A project Owner must grant these roles to the deployer service account."
  echo "  Run the following commands as Owner:"
  echo ""

  # If the deployer SA name doesn't match the docs, include rename instructions
  if [[ "${deployer_email}" != "openclaw-deployer@${PROJECT_ID}.iam.gserviceaccount.com" ]]; then
    echo "  ── Option A: Create the correct deployer SA (recommended) ──"
    echo ""
    echo "    # 1. Create the openclaw-deployer service account"
    echo "    gcloud iam service-accounts create openclaw-deployer \\"
    echo "      --display-name='OpenClaw Deployer' \\"
    echo "      --project=${PROJECT_ID}"
    echo ""
    echo "    # 2. Grant all required roles"
    echo "    for ROLE in roles/compute.admin roles/iam.securityAdmin \\"
    echo "               roles/serviceusage.serviceUsageAdmin \\"
    echo "               roles/iam.serviceAccountAdmin roles/secretmanager.admin; do"
    echo "      gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
    echo "        --member='serviceAccount:openclaw-deployer@${PROJECT_ID}.iam.gserviceaccount.com' \\"
    echo "        --role=\"\${ROLE}\""
    echo "    done"
    echo ""
    echo "    # 3. Create and download a key"
    echo "    gcloud iam service-accounts keys create key.json \\"
    echo "      --iam-account='openclaw-deployer@${PROJECT_ID}.iam.gserviceaccount.com'"
    echo "    base64 -w 0 key.json   # copy output → GCP_SERVICE_ACCOUNT_KEY secret"
    echo "    rm key.json"
    echo ""
    echo "    # 4. (Optional) Delete the old service account"
    echo "    gcloud iam service-accounts delete '${deployer_email}' \\"
    echo "      --project=${PROJECT_ID} --quiet"
    echo ""
    echo "  ── Option B: Grant roles to the existing SA ────────────────"
    echo ""
  fi

  for role in "${missing_roles[@]}"; do
    echo "    gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
    echo "      --member='serviceAccount:${deployer_email}' \\"
    echo "      --role='${role}'"
  done
  echo ""
  echo "  Then re-run this script."
  exit 1
}

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  GCP IAP-Only VPS + OpenClaw Deployment"
echo "════════════════════════════════════════════════════════════"
echo "  Project  : ${PROJECT_ID}"
echo "  Zone     : ${ZONE}"
echo "  Region   : ${REGION}"
echo "  Instance : ${INSTANCE_NAME}"
echo "  Type     : ${MACHINE_TYPE}"
echo "  Disk     : ${BOOT_DISK_SIZE} ${BOOT_DISK_TYPE}"
echo "════════════════════════════════════════════════════════════"
echo ""

check_deployer_permissions

# ─── Enable required APIs ────────────────────────────────────────────────────
echo "▶ Enabling required APIs…"

REQUIRED_APIS="compute.googleapis.com iap.googleapis.com secretmanager.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com"

if gcloud services enable ${REQUIRED_APIS} \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null; then
  echo "  ✓ APIs enabled"
else
  echo "  ⚠  Could not enable APIs (may lack serviceusage permissions)."
  echo "     Checking if they are already enabled…"
  MISSING_APIS=""
  for API in ${REQUIRED_APIS}; do
    if ! gcloud services list --project="${PROJECT_ID}" --filter="name:${API}" --format="value(name)" 2>/dev/null | grep -q "${API}"; then
      MISSING_APIS="${MISSING_APIS} ${API}"
    fi
  done
  if [[ -n "${MISSING_APIS}" ]]; then
    echo "  ⚠  Missing APIs:${MISSING_APIS}"
    echo "     A project Owner should run:"
    echo "       gcloud services enable${MISSING_APIS} --project=${PROJECT_ID}"
    echo ""
    echo "     Continuing with available APIs…"
  else
    echo "  ✓ APIs already enabled"
  fi
fi

# ─── Secret Manager: create VM service account ──────────────────────────────
# Each secret in this project becomes an env var (NAME=value). No manifest or
# bundle — the VM enumerates all secrets at startup. This project should be
# dedicated to this deployment.
echo ""
echo "▶ Setting up Secret Manager for OpenClaw secrets…"

SM_READY=false

# Check if Secret Manager API is available
if gcloud services list --project="${PROJECT_ID}" --filter="name:secretmanager.googleapis.com" \
   --format="value(name)" 2>/dev/null | grep -q "secretmanager"; then

  # Create VM service account (for Secret Manager access)
  SA_ERR=""
  if gcloud iam service-accounts describe "${VM_SA_EMAIL}" \
       --project="${PROJECT_ID}" &>/dev/null; then
    echo "  Service account ${VM_SA_NAME} already exists."
  else
    SA_ERR="$(gcloud iam service-accounts create "${VM_SA_NAME}" \
         --display-name="OpenClaw VM (${INSTANCE_NAME})" \
         --project="${PROJECT_ID}" --quiet 2>&1)" && {
      echo "  ✓ Created service account ${VM_SA_NAME}"
    } || {
      echo "  ✗ Could not create service account ${VM_SA_NAME}:"
      echo "    ${SA_ERR}" | head -3
      echo ""
      echo "    The deployer needs roles/iam.serviceAccountAdmin. A project Owner should run:"
      echo "      gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
      echo "        --member='serviceAccount:$(gcloud config get-value account 2>/dev/null)' \\"
      echo "        --role='roles/iam.serviceAccountAdmin'"
    }
  fi

  # Grant secretmanager.secretAccessor (read values) and secretmanager.viewer
  # (list secrets) to the VM service account
  if gcloud iam service-accounts describe "${VM_SA_EMAIL}" \
       --project="${PROJECT_ID}" &>/dev/null; then
    BIND_ERR=""
    for SM_ROLE in roles/secretmanager.secretAccessor roles/secretmanager.viewer; do
      BIND_ERR="$(gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${VM_SA_EMAIL}" \
        --role="${SM_ROLE}" \
        --condition=None \
        --quiet 2>&1)" || {
        echo "  ✗ Could not grant ${SM_ROLE} to ${VM_SA_EMAIL}:"
        echo "    ${BIND_ERR}" | head -2
        echo "    The deployer needs roles/iam.securityAdmin to manage IAM bindings."
      }
    done

    # The deployer needs iam.serviceAccountUser on the VM SA to attach it
    DEPLOYER_EMAIL="$(gcloud config get-value account 2>/dev/null)"
    if [[ -n "${DEPLOYER_EMAIL}" ]]; then
      # Detect whether the active account is a service account or a user
      if [[ "${DEPLOYER_EMAIL}" == *"iam.gserviceaccount.com" ]]; then
        MEMBER_PREFIX="serviceAccount"
      else
        MEMBER_PREFIX="user"
      fi
      gcloud iam service-accounts add-iam-policy-binding "${VM_SA_EMAIL}" \
        --member="${MEMBER_PREFIX}:${DEPLOYER_EMAIL}" \
        --role="roles/iam.serviceAccountUser" \
        --project="${PROJECT_ID}" \
        --quiet 2>/dev/null || true
    fi
    SM_READY=true
  fi

  if [[ "${SM_READY}" == "true" ]]; then
    echo "  ✓ Secret Manager configured"
  fi
else
  echo "  ⚠  Secret Manager API not enabled — skipping."
fi

# ─── Pre-create OpenClaw secrets (placeholder values) ─────────────────────
# Creates secrets that don't exist yet so the user only needs to fill in values.
# Required secrets get a "REPLACE_ME" placeholder; optional ones get "DISABLED".
if [[ "${SM_READY}" == "true" ]]; then
  echo ""
  echo "▶ Pre-creating OpenClaw secrets (placeholders for unconfigured ones)…"

  # Format: "SECRET_NAME|PLACEHOLDER|CATEGORY"
  # Categories: required, provider, channel, gateway
  OPENCLAW_SECRETS=(
    # ── Required ──────────────────────────────────────────────────────────
    "ANTHROPIC_API_KEY|REPLACE_ME|required"

    # ── Optional AI providers ─────────────────────────────────────────────
    "OPENAI_API_KEY|DISABLED|provider"
    "OPENROUTER_API_KEY|DISABLED|provider"
    "GEMINI_API_KEY|DISABLED|provider"
    "XAI_API_KEY|DISABLED|provider"
    "GROQ_API_KEY|DISABLED|provider"
    "MISTRAL_API_KEY|DISABLED|provider"
    "DEEPGRAM_API_KEY|DISABLED|provider"

    # ── Channel: Telegram ─────────────────────────────────────────────────
    "TELEGRAM_BOT_TOKEN|DISABLED|channel"

    # ── Channel: Discord ──────────────────────────────────────────────────
    "DISCORD_BOT_TOKEN|DISABLED|channel"

    # ── Channel: Slack ────────────────────────────────────────────────────
    "SLACK_BOT_TOKEN|DISABLED|channel"
    "SLACK_APP_TOKEN|DISABLED|channel"

    # ── Gateway / auth ────────────────────────────────────────────────────
    "OPENCLAW_PRIMARY_MODEL|claude-sonnet-4-20250514|gateway"
  )

  CREATED=0
  EXISTING=0

  for ENTRY in "${OPENCLAW_SECRETS[@]}"; do
    SECRET_NAME="${ENTRY%%|*}"
    REST="${ENTRY#*|}"
    PLACEHOLDER="${REST%%|*}"
    CATEGORY="${REST#*|}"

    if gcloud secrets describe "${SECRET_NAME}" \
         --project="${PROJECT_ID}" &>/dev/null; then
      EXISTING=$((EXISTING + 1))
    else
      printf '%s' "${PLACEHOLDER}" \
        | gcloud secrets create "${SECRET_NAME}" \
            --project="${PROJECT_ID}" \
            --data-file=- \
            --quiet 2>/dev/null && {
        CREATED=$((CREATED + 1))
      } || {
        echo "  ✗ Could not create secret ${SECRET_NAME}"
      }
    fi
  done

  echo "  ✓ Secrets: ${CREATED} created, ${EXISTING} already existed"

  # Show which required secrets still need real values
  NEEDS_UPDATE=()
  for ENTRY in "${OPENCLAW_SECRETS[@]}"; do
    SECRET_NAME="${ENTRY%%|*}"
    REST="${ENTRY#*|}"
    PLACEHOLDER="${REST%%|*}"
    CATEGORY="${REST#*|}"

    if [[ "${CATEGORY}" == "required" ]]; then
      CURRENT_VALUE="$(gcloud secrets versions access latest \
        --secret="${SECRET_NAME}" --project="${PROJECT_ID}" 2>/dev/null)" || continue
      if [[ "${CURRENT_VALUE}" == "REPLACE_ME" ]]; then
        NEEDS_UPDATE+=("${SECRET_NAME}")
      fi
    fi
  done

  if [[ ${#NEEDS_UPDATE[@]} -gt 0 ]]; then
    echo ""
    echo "  ⚠ Required secrets that still need real values:"
    for S in "${NEEDS_UPDATE[@]}"; do
      echo "      • ${S}"
    done
    echo ""
    echo "    Update with:"
    echo "      gcloud secrets versions add SECRET_NAME --project=${PROJECT_ID} --data-file=- <<< 'real-value'"
  fi
fi

if [[ "${SM_READY}" != "true" ]]; then
  echo ""
  echo "  To enable Secret Manager, a project Owner should run:"
  echo ""
  echo "    gcloud services enable secretmanager.googleapis.com iam.googleapis.com \\"
  echo "      --project=${PROJECT_ID}"
  echo ""
  echo "    gcloud iam service-accounts create ${VM_SA_NAME} \\"
  echo "      --display-name='OpenClaw VM (${INSTANCE_NAME})' \\"
  echo "      --project=${PROJECT_ID}"
  echo ""
  echo "    for ROLE in roles/secretmanager.secretAccessor roles/secretmanager.viewer; do"
  echo "      gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
  echo "        --member='serviceAccount:${VM_SA_EMAIL}' \\"
  echo "        --role=\"\${ROLE}\""
  echo "    done"
  echo ""
  echo "  Then re-run this script to attach the service account to the VM."
fi

# ─── Firewall: allow SSH only from IAP ───────────────────────────────────────
echo ""
echo "▶ Configuring firewall rule '${FIREWALL_RULE_NAME}' (IAP → SSH only)…"

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  echo "  Rule already exists — updating."
  gcloud compute firewall-rules update "${FIREWALL_RULE_NAME}" \
    --project="${PROJECT_ID}" \
    --allow="tcp:22" \
    --source-ranges="${IAP_CIDR}" \
    --quiet
else
  gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="tcp:22" \
    --source-ranges="${IAP_CIDR}" \
    --target-tags="iap-ssh" \
    --description="Allow SSH only through Identity-Aware Proxy" \
    --quiet
fi
echo "  ✓ Firewall rule configured"

# ─── Firewall: deny all other ingress SSH ────────────────────────────────────
DENY_RULE_NAME="${FIREWALL_RULE_NAME}-deny-public"
echo ""
echo "▶ Configuring deny-all-public-ssh rule '${DENY_RULE_NAME}'…"

if gcloud compute firewall-rules describe "${DENY_RULE_NAME}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  echo "  Rule already exists — skipping."
else
  gcloud compute firewall-rules create "${DENY_RULE_NAME}" \
    --project="${PROJECT_ID}" \
    --network="${NETWORK}" \
    --direction=INGRESS \
    --action=DENY \
    --rules="tcp:22" \
    --source-ranges="0.0.0.0/0" \
    --priority=2000 \
    --target-tags="iap-ssh" \
    --description="Deny direct SSH from the public internet" \
    --quiet
fi
echo "  ✓ Public SSH blocked"

# ─── Cloud NAT: outbound internet for private VM ────────────────────────────
ROUTER_NAME="${INSTANCE_NAME}-router"
NAT_NAME="${INSTANCE_NAME}-nat"

echo ""
echo "▶ Configuring Cloud NAT for outbound internet access…"

if ! gcloud compute routers describe "${ROUTER_NAME}" \
     --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute routers create "${ROUTER_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --network="${NETWORK}" \
    --quiet
fi

if ! gcloud compute routers nats describe "${NAT_NAME}" \
     --router="${ROUTER_NAME}" --region="${REGION}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute routers nats create "${NAT_NAME}" \
    --router="${ROUTER_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --quiet
fi
echo "  ✓ Cloud NAT configured"

# ─── Create VM instance ───────────────────────────────────────────────────────
echo ""
echo "▶ Creating VM instance '${INSTANCE_NAME}'…"

if gcloud compute instances describe "${INSTANCE_NAME}" \
     --zone="${ZONE}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  echo "  Instance already exists — skipping creation."

  # If Secret Manager is now ready but the VM has no service account, attach one.
  # This handles the case where the initial deploy ran before APIs were enabled.
  if [[ "${SM_READY}" == "true" ]]; then
    CURRENT_SA="$(gcloud compute instances describe "${INSTANCE_NAME}" \
      --zone="${ZONE}" --project="${PROJECT_ID}" \
      --format="value(serviceAccounts[0].email)" 2>/dev/null)"
    if [[ -z "${CURRENT_SA}" || "${CURRENT_SA}" == "None" ]]; then
      echo "  VM has no service account — attaching ${VM_SA_EMAIL}…"
      echo "  (Requires stop/start)"
      gcloud compute instances stop "${INSTANCE_NAME}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
      gcloud compute instances set-service-account "${INSTANCE_NAME}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" \
        --service-account="${VM_SA_EMAIL}" \
        --scopes="https://www.googleapis.com/auth/cloud-platform"
      gcloud compute instances start "${INSTANCE_NAME}" \
        --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
      echo "  ✓ Service account attached and VM restarted"
    fi
  fi
else
  # Build service account flags
  SA_FLAGS=()
  if [[ "${SM_READY}" == "true" ]]; then
    SA_FLAGS+=(--service-account="${VM_SA_EMAIL}")
    SA_FLAGS+=(--scopes="https://www.googleapis.com/auth/cloud-platform")
    echo "  Using service account: ${VM_SA_EMAIL}"
  else
    SA_FLAGS+=(--no-service-account)
    SA_FLAGS+=(--no-scopes)
    echo "  No service account (Secret Manager not configured)."
  fi

  gcloud compute instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --network="${NETWORK}" \
    --no-address \
    "${SA_FLAGS[@]}" \
    --tags="iap-ssh" \
    --metadata="enable-oslogin=TRUE" \
    --metadata-from-file="startup-script=${SCRIPT_DIR}/startup.sh" \
    --boot-disk-type="${BOOT_DISK_TYPE}" \
    --boot-disk-size="${BOOT_DISK_SIZE}" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --quiet
fi
echo "  ✓ Instance ready"

# ─── Grant current user IAP-tunnelled SSH access ─────────────────────────────
echo ""
echo "▶ Granting IAP-tunnel access…"
CURRENT_USER_EMAIL="$(gcloud config get-value account 2>/dev/null)"

if [[ -n "${CURRENT_USER_EMAIL}" ]]; then
  if [[ "${CURRENT_USER_EMAIL}" == *"iam.gserviceaccount.com" ]]; then
    echo "  Deployer is a service account — skipping IAP self-grant."
    echo "  To grant IAP access to a human user, run:"
    echo ""
    echo "    gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
    echo "      --member='user:YOU@example.com' \\"
    echo "      --role='roles/iap.tunnelResourceAccessor'"
  else
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="user:${CURRENT_USER_EMAIL}" \
      --role="roles/iap.tunnelResourceAccessor" \
      --condition=None \
      --quiet 2>/dev/null || true
    echo "  ✓ IAP access granted to ${CURRENT_USER_EMAIL}"
  fi
else
  echo "  ⚠  Could not detect current user — grant IAP access manually:"
  echo "     gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
  echo "       --member='user:YOU@example.com' \\"
  echo "       --role='roles/iap.tunnelResourceAccessor'"
fi

# ─── Post-deploy health check ─────────────────────────────────────────────────
echo ""
echo "▶ Deployment health check…"

HEALTH_ISSUES=0

# Check VM status
VM_STATUS="$(gcloud compute instances describe "${INSTANCE_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format="value(status)" 2>/dev/null)" || VM_STATUS="NOT_FOUND"
if [[ "${VM_STATUS}" == "RUNNING" ]]; then
  echo "  ✓ VM status: RUNNING"
else
  echo "  ✗ VM status: ${VM_STATUS}"
  HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
fi

# Check VM service account
VM_SA="$(gcloud compute instances describe "${INSTANCE_NAME}" \
  --zone="${ZONE}" --project="${PROJECT_ID}" \
  --format="value(serviceAccounts[0].email)" 2>/dev/null)" || VM_SA=""
if [[ -n "${VM_SA}" && "${VM_SA}" != "None" ]]; then
  echo "  ✓ VM service account: ${VM_SA}"
else
  echo "  ✗ VM has no service account — cannot access Secret Manager"
  echo "    Re-run this script after granting the deployer the required roles."
  HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
fi

# Check for secrets in Secret Manager
SECRET_COUNT="$(gcloud secrets list --project="${PROJECT_ID}" \
  --format="value(name)" 2>/dev/null | wc -l)" || SECRET_COUNT=0
if [[ "${SECRET_COUNT}" -gt 0 ]]; then
  echo "  ✓ Secret Manager: ${SECRET_COUNT} secret(s) found"
  # Check if ANTHROPIC_API_KEY has a real value
  ANTHRO_VAL="$(gcloud secrets versions access latest \
    --secret="ANTHROPIC_API_KEY" --project="${PROJECT_ID}" 2>/dev/null)" || ANTHRO_VAL=""
  if [[ "${ANTHRO_VAL}" == "REPLACE_ME" || -z "${ANTHRO_VAL}" ]]; then
    echo "  ⚠ ANTHROPIC_API_KEY still needs a real value"
    HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
  else
    echo "  ✓ ANTHROPIC_API_KEY is configured"
  fi
else
  echo "  ⚠ No secrets in Secret Manager yet"
  HEALTH_ISSUES=$((HEALTH_ISSUES + 1))
fi

if [[ "${HEALTH_ISSUES}" -gt 0 ]]; then
  echo ""
  echo "  ⚠ ${HEALTH_ISSUES} issue(s) detected — see messages above."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
if [[ "${HEALTH_ISSUES}" -eq 0 ]]; then
  echo "  Deployment complete!"
else
  echo "  Deployment complete (with ${HEALTH_ISSUES} warning(s))"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Connect to your VPS via IAP:"
echo ""
echo "    gcloud compute ssh ${INSTANCE_NAME} \\"
echo "      --project=${PROJECT_ID} \\"
echo "      --zone=${ZONE} \\"
echo "      --tunnel-through-iap"
echo ""
echo "  The instance has NO public IP. All SSH traffic is"
echo "  routed securely through Google's Identity-Aware Proxy."
echo ""
echo "  OpenClaw is being installed on the VM (2-3 minutes on"
echo "  first boot while Node.js and OpenClaw are downloaded)."
echo ""
echo "  After connecting via SSH, check the service:"
echo ""
echo "    sudo systemctl status openclaw-gateway"
echo "    sudo journalctl -u openclaw-gateway -f"
echo ""
echo "  ── OpenClaw Web UI ────────────────────────────────────"
echo ""
echo "  Access the web UI securely through an IAP SSH tunnel:"
echo ""
echo "    gcloud compute ssh ${INSTANCE_NAME} \\"
echo "      --project=${PROJECT_ID} \\"
echo "      --zone=${ZONE} \\"
echo "      --tunnel-through-iap \\"
echo "      -- -L 18789:localhost:18789"
echo ""
echo "  Then open http://localhost:18789 in your browser."
echo "  The tunnel stays open as long as the SSH session is active."
echo ""
echo "  ── Secrets Management ──────────────────────────────────"
echo ""
echo "  Secrets are pre-created with placeholder values."
echo "  Update the required one(s) with real values:"
echo ""
echo "    gcloud secrets versions add ANTHROPIC_API_KEY \\"
echo "      --project=${PROJECT_ID} \\"
echo "      --data-file=- <<< 'sk-ant-api03-...'"
echo ""
echo "  Optional — enable channels by updating their tokens:"
echo ""
echo "    gcloud secrets versions add TELEGRAM_BOT_TOKEN \\"
echo "      --project=${PROJECT_ID} --data-file=- <<< 'bot-token'"
echo ""
echo "    gcloud secrets versions add DISCORD_BOT_TOKEN \\"
echo "      --project=${PROJECT_ID} --data-file=- <<< 'bot-token'"
echo ""
echo "    gcloud secrets versions add SLACK_BOT_TOKEN \\"
echo "      --project=${PROJECT_ID} --data-file=- <<< 'xoxb-...'"
echo "    gcloud secrets versions add SLACK_APP_TOKEN \\"
echo "      --project=${PROJECT_ID} --data-file=- <<< 'xapp-...'"
echo ""
echo "  List all secrets:  gcloud secrets list --project=${PROJECT_ID}"
echo ""
echo "  After updating secrets, restart the service:"
echo ""
echo "    gcloud compute ssh ${INSTANCE_NAME} --tunnel-through-iap \\"
echo "      --project=${PROJECT_ID} --zone=${ZONE} \\"
echo "      -- sudo systemctl restart openclaw-gateway"
echo ""
echo "  ⚠  This project should be dedicated to this deployment."
echo "     All secrets in the project are loaded into OpenClaw."
echo "     Secrets set to \"DISABLED\" are ignored by OpenClaw."
echo "════════════════════════════════════════════════════════════"
