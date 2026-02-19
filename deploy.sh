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

# ─── Enable required APIs ────────────────────────────────────────────────────
echo "▶ Enabling required APIs…"
if gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null; then
  echo "  ✓ APIs enabled"
else
  echo "  ⚠  Could not enable APIs (may lack serviceusage permissions)."
  echo "     Checking if they are already enabled…"
  MISSING=0
  for API in compute.googleapis.com iap.googleapis.com; do
    if ! gcloud services list --project="${PROJECT_ID}" --filter="name:${API}" --format="value(name)" 2>/dev/null | grep -q "${API}"; then
      echo "     ✗ ${API} is NOT enabled — enable it manually."
      MISSING=1
    fi
  done
  if [[ "${MISSING}" -eq 1 ]]; then
    echo "  ERROR: Required APIs are not enabled. Ask a project Owner to run:"
    echo "    gcloud services enable compute.googleapis.com iap.googleapis.com --project=${PROJECT_ID}"
    exit 1
  fi
  echo "  ✓ APIs already enabled"
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
else
  gcloud compute instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --network="${NETWORK}" \
    --no-address \
    --no-service-account \
    --no-scopes \
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
echo "▶ Granting IAP-tunnel access to the current user…"
CURRENT_USER_EMAIL="$(gcloud config get-value account 2>/dev/null)"

if [[ -n "${CURRENT_USER_EMAIL}" ]]; then
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${CURRENT_USER_EMAIL}" \
    --role="roles/iap.tunnelResourceAccessor" \
    --condition=None \
    --quiet 2>/dev/null || true
  echo "  ✓ IAP access granted to ${CURRENT_USER_EMAIL}"
else
  echo "  ⚠  Could not detect current user — grant IAP access manually:"
  echo "     gcloud projects add-iam-policy-binding ${PROJECT_ID} \\"
  echo "       --member='user:YOU@example.com' \\"
  echo "       --role='roles/iap.tunnelResourceAccessor'"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Deployment complete!"
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
echo "  Configure API keys and messaging platforms:"
echo ""
echo "    sudo -u openclaw openclaw config"
echo "════════════════════════════════════════════════════════════"
