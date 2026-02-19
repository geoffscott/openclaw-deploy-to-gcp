# Deploy an IAP-Only VPS with OpenClaw on GCP

This tutorial walks you through deploying a secure virtual machine with [OpenClaw](https://openclaw.ai/) pre-installed. The VM is **only reachable through Google's [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)** — no public IP, no open SSH port on the internet. Secrets are stored in Secret Manager and never written to persistent disk.

---

## Step 1 — Select your project

Make sure you are working in the right GCP project.

```bash
gcloud config set project <YOUR_PROJECT_ID>
```

You can list your projects with:

```bash
gcloud projects list
```

Click **Next** when ready.

---

## Step 2 — Review the deployment script

Open <walkthrough-editor-open-file filePath="deploy.sh">deploy.sh</walkthrough-editor-open-file> to review what the script does before running it.

Key actions performed by the script:

| Step | What happens |
|------|-------------|
| Enable APIs | `compute`, `iap`, `secretmanager`, `iam` |
| Secret Manager | Creates a VM service account for reading secrets |
| Firewall (allow) | SSH (`tcp:22`) from IAP range `35.235.240.0/20` only |
| Firewall (deny) | Direct SSH from `0.0.0.0/0` blocked |
| Cloud NAT | Outbound-only internet for the private VM |
| VM creation | `e2-medium`, 20 GB SSD, no external IP, OS Login, Shielded VM |
| Startup script | Installs Node.js 22 and OpenClaw; starts `openclaw-gateway` service |
| IAM binding | Grants your account `roles/iap.tunnelResourceAccessor` |

---

## Step 3 — Run the deploy script

Run the deployment with default settings:

```bash
bash deploy.sh
```

Or customise it:

```bash
bash deploy.sh --name my-vps --zone europe-west1-b --machine-type e2-small
```

Available flags:

| Flag | Default | Description |
|------|---------|-------------|
| `--project` | current gcloud project | GCP project ID |
| `--zone` | `us-central1-a` | Compute zone |
| `--name` | `iap-vps` | VM instance name |
| `--machine-type` | `e2-medium` | Machine type (e2-medium recommended for OpenClaw) |

The script is **idempotent** — safe to run multiple times.

---

## Step 4 — Configure OpenClaw

First, SSH into the VM and run the OpenClaw setup wizard to register the gateway:

```bash
gcloud compute ssh iap-vps --zone=us-central1-a --tunnel-through-iap
sudo -u openclaw openclaw setup
```

Copy the gateway token printed at the end of setup, then store it and your API keys as secrets. Each secret in the project becomes an environment variable for OpenClaw (injected at startup, never written to disk).

**Using the CLI:**

```bash
gcloud secrets create OPENCLAW_GATEWAY_TOKEN --data-file=- <<< '<token-from-setup>'
gcloud secrets create ANTHROPIC_API_KEY --data-file=- <<< 'sk-ant-...'
```

**Or using the GCP Console:**

Open [Secret Manager](https://console.cloud.google.com/security/secret-manager), click **Create Secret**, and add each key-value pair.

Then restart the service to load the new secrets:

```bash
gcloud compute ssh iap-vps --tunnel-through-iap \
  -- sudo systemctl restart openclaw-gateway
```

---

## Step 5 — Connect to your VPS

Once deployment finishes, SSH into the instance through IAP:

```bash
gcloud compute ssh iap-vps \
  --zone=us-central1-a \
  --tunnel-through-iap
```

Replace `iap-vps` and `us-central1-a` with your chosen instance name and zone if you used custom values.

> **How it works:** gcloud opens an encrypted tunnel to Google's IAP service, which authenticates your identity before forwarding traffic to the VM. The VM never exposes port 22 to the public internet.

---

## Step 6 — Verify OpenClaw

OpenClaw is installed automatically on first boot (takes 2-3 minutes). Check the service status:

```bash
sudo systemctl status openclaw-gateway
```

Watch the logs:

```bash
sudo journalctl -u openclaw-gateway -f
```

To pick up new secrets after updating them in Secret Manager:

```bash
sudo systemctl restart openclaw-gateway
```

---

## Step 7 — Verify access control

Confirm the instance has no external IP:

```bash
gcloud compute instances describe iap-vps \
  --zone=us-central1-a \
  --format="get(networkInterfaces[0].accessConfigs)"
```

The output should be empty — no `natIP` means no public address.

---

## Cleanup

To tear down all resources created by this deployment:

```bash
# Delete the VM
gcloud compute instances delete iap-vps --zone=us-central1-a --quiet

# Delete firewall rules
gcloud compute firewall-rules delete allow-iap-ssh --quiet
gcloud compute firewall-rules delete allow-iap-ssh-deny-public --quiet

# Delete Cloud NAT and router
gcloud compute routers nats delete iap-vps-nat \
  --router=iap-vps-router --region=us-central1 --quiet
gcloud compute routers delete iap-vps-router --region=us-central1 --quiet

# Delete all secrets and VM service account
for SECRET in $(gcloud secrets list --project=YOUR_PROJECT_ID --format="value(name)"); do
  gcloud secrets delete "${SECRET}" --project=YOUR_PROJECT_ID --quiet
done
gcloud iam service-accounts delete iap-vps-vm-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com \
  --project=YOUR_PROJECT_ID --quiet
```

---

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

**Deployment complete!** Your VPS is running OpenClaw with IAP-only access — no exposed ports, no public IP, secrets in RAM only. Add your API keys to Secret Manager and restart the service to get started.
