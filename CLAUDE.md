# Claude Code — Project Instructions

This repository deploys an IAP-only VPS on Google Cloud Platform with OpenClaw
pre-installed using `deploy.sh`. Secrets are managed through GCP Secret Manager
and injected into the OpenClaw process at startup — never written to persistent disk.

## Environment Setup

The session-start hook (`.claude/hooks/session-start.sh`) automatically installs
`gcloud` and authenticates on every cloud session. Two environment variables must
be set as secrets in the Claude Code environment settings:

| Variable | Description |
|---|---|
| `GCP_SERVICE_ACCOUNT_KEY` | Service account JSON key, **base64-encoded** |
| `GCP_PROJECT_ID` | GCP project ID (e.g. `my-project-123`) |

### Creating the deployer service account and key (one-time setup)

This creates a service account that `deploy.sh` uses to provision infrastructure.
The script separately creates a second SA (`iap-vps-vm-sa`) for the VM at runtime.

```bash
# Create deployer service account
gcloud iam service-accounts create openclaw-deployer \
  --display-name="OpenClaw Deployer" \
  --project=YOUR_PROJECT_ID

# Grant required roles
for ROLE in roles/compute.admin roles/iam.securityAdmin roles/serviceusage.serviceUsageAdmin roles/iam.serviceAccountAdmin roles/secretmanager.admin; do
  gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member="serviceAccount:openclaw-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role="${ROLE}"
done

# Download key and base64-encode it for the env var
gcloud iam service-accounts keys create key.json \
  --iam-account="openclaw-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com"

base64 -w 0 key.json   # copy this output → GCP_SERVICE_ACCOUNT_KEY secret
rm key.json
```

### Required APIs (enable as project Owner if the deployer SA cannot)

```bash
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=YOUR_PROJECT_ID
```

## Running the deploy script

```bash
bash deploy.sh --project "${GCP_PROJECT_ID}"
# or with custom zone/name/machine-type:
bash deploy.sh --project "${GCP_PROJECT_ID}" --zone us-west1-b --name my-vps --machine-type e2-small
```

The script is **idempotent** — safe to run multiple times.

## Managing OpenClaw secrets

Each secret in the GCP project becomes an environment variable. The VM
enumerates all secrets at startup and writes them to `/run/openclaw/env`
(tmpfs — RAM only, never on disk). This project should be dedicated to
this deployment.

```bash
# Add a new secret
gcloud secrets create ANTHROPIC_API_KEY \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'sk-ant-...'

# Update an existing secret
gcloud secrets versions add ANTHROPIC_API_KEY \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'sk-ant-new-key...'

# Restart service to pick up new secrets
gcloud compute ssh iap-vps --zone=us-central1-a \
  --tunnel-through-iap --project="${GCP_PROJECT_ID}" \
  -- sudo systemctl restart openclaw-gateway
```

### Credential isolation on the VM

| Path | Protection |
|------|-----------|
| `/run/openclaw/env` | tmpfs — secrets exist only in RAM |
| `~/.openclaw/credentials/` | Bind-mounted to tmpfs |
| `~/.openclaw/.env` | Symlinked to `/dev/null` |

## Verifying provisioned resources

After running `deploy.sh`, use these commands to verify each resource:

```bash
# VM instance
gcloud compute instances describe iap-vps \
  --zone=us-central1-a --project="${GCP_PROJECT_ID}" \
  --format="table(name,status,networkInterfaces[0].accessConfigs[0].natIP)"

# Firewall rules
gcloud compute firewall-rules list \
  --project="${GCP_PROJECT_ID}" \
  --filter="name~allow-iap-ssh" \
  --format="table(name,direction,allowed[].map().firewall_rule().list():label=ALLOW,sourceRanges.list())"

# APIs enabled
gcloud services list --project="${GCP_PROJECT_ID}" \
  --filter="name:(compute.googleapis.com OR iap.googleapis.com OR secretmanager.googleapis.com)" \
  --format="table(name,state)"

# IAP IAM binding
gcloud projects get-iam-policy "${GCP_PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iap.tunnelResourceAccessor" \
  --format="table(bindings.members)"

# Cloud NAT
gcloud compute routers nats describe iap-vps-nat \
  --router=iap-vps-router --region=us-central1 \
  --project="${GCP_PROJECT_ID}"

# Secret Manager secrets (list all)
gcloud secrets list --project="${GCP_PROJECT_ID}" --format="table(name)"

# OpenClaw startup script output (from serial console)
gcloud compute instances get-serial-port-output iap-vps \
  --zone=us-central1-a --project="${GCP_PROJECT_ID}" \
  | grep openclaw-startup

# OpenClaw service status (via SSH)
gcloud compute ssh iap-vps --zone=us-central1-a \
  --tunnel-through-iap --project="${GCP_PROJECT_ID}" \
  -- sudo systemctl status openclaw-gateway
```

## Cleanup

```bash
gcloud compute instances delete iap-vps --zone=us-central1-a \
  --project="${GCP_PROJECT_ID}" --quiet
gcloud compute firewall-rules delete allow-iap-ssh allow-iap-ssh-deny-public \
  --project="${GCP_PROJECT_ID}" --quiet
gcloud compute routers nats delete iap-vps-nat \
  --router=iap-vps-router --region=us-central1 \
  --project="${GCP_PROJECT_ID}" --quiet
gcloud compute routers delete iap-vps-router --region=us-central1 \
  --project="${GCP_PROJECT_ID}" --quiet
for SECRET in $(gcloud secrets list --project="${GCP_PROJECT_ID}" --format="value(name)"); do
  gcloud secrets delete "${SECRET}" --project="${GCP_PROJECT_ID}" --quiet
done
gcloud iam service-accounts delete iap-vps-vm-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com \
  --project="${GCP_PROJECT_ID}" --quiet
```
