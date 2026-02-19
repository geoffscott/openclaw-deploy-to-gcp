# Claude Code — Project Instructions

This repository deploys an IAP-only VPS on Google Cloud Platform using `deploy.sh`.

## Environment Setup

The session-start hook (`.claude/hooks/session-start.sh`) automatically installs
`gcloud` and authenticates on every cloud session. Two environment variables must
be set as secrets in the Claude Code environment settings:

| Variable | Description |
|---|---|
| `GCP_SERVICE_ACCOUNT_KEY` | Service account JSON key, **base64-encoded** |
| `GCP_PROJECT_ID` | GCP project ID (e.g. `my-project-123`) |

### Creating the service account and key (one-time setup)

```bash
# Create service account
gcloud iam service-accounts create claude-deployer \
  --display-name="Claude Code Deployer" \
  --project=YOUR_PROJECT_ID

# Grant required roles
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:claude-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:claude-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.securityAdmin"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:claude-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/serviceusage.serviceUsageAdmin"

# Download key and base64-encode it for the env var
gcloud iam service-accounts keys create key.json \
  --iam-account="claude-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com"

base64 -w 0 key.json   # copy this output → GCP_SERVICE_ACCOUNT_KEY secret
rm key.json
```

## Running the deploy script

```bash
bash deploy.sh --project "${GCP_PROJECT_ID}"
# or with custom zone/name:
bash deploy.sh --project "${GCP_PROJECT_ID}" --zone us-west1-b --name my-vps
```

The script is **idempotent** — safe to run multiple times.

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
  --filter="name:(compute.googleapis.com OR iap.googleapis.com)" \
  --format="table(name,state)"

# IAP IAM binding
gcloud projects get-iam-policy "${GCP_PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iap.tunnelResourceAccessor" \
  --format="table(bindings.members)"
```

## Cleanup

```bash
gcloud compute instances delete iap-vps --zone=us-central1-a \
  --project="${GCP_PROJECT_ID}" --quiet
gcloud compute firewall-rules delete allow-iap-ssh allow-iap-ssh-deny-public \
  --project="${GCP_PROJECT_ID}" --quiet
```
