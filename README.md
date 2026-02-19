# GCP IAP-Only VPS + OpenClaw — One-Click Deploy

Deploy a secure virtual machine on Google Cloud with [OpenClaw](https://openclaw.ai/) pre-installed. The VM is **only accessible through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)** — no public IP address, no SSH port open to the internet. Access is gated entirely by your Google identity.

---

## Deploy to GCP

Click the button below to open this repo in Cloud Shell and follow the interactive tutorial:

[![Deploy to GCP](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/geoffscott/openclaw-deploy-to-gcp&cloudshell_tutorial=cloudshell_tutorial.md)

---

## What gets deployed

| Resource | Details |
|----------|---------|
| **VM instance** | `e2-medium` (2 vCPU, 4 GB), Debian 12, Shielded VM, **no external IP**, 20 GB SSD |
| **OpenClaw** | Installed via startup script; runs as `openclaw-gateway` systemd service on port 18789 |
| **Cloud NAT** | Outbound-only internet for the private VM (package downloads, API calls) |
| **Cloud Router** | Required by Cloud NAT |
| **Firewall (allow)** | SSH (`tcp:22`) from IAP range `35.235.240.0/20` only |
| **Firewall (deny)** | Direct SSH from `0.0.0.0/0` blocked |
| **OS Login** | Enabled — SSH keys managed via IAM |
| **IAM binding** | Deploying user receives `roles/iap.tunnelResourceAccessor` |

APIs enabled automatically: `compute.googleapis.com`, `iap.googleapis.com`

---

## Prerequisites

- A GCP project with [billing enabled](https://cloud.google.com/billing/docs/how-to/manage-billing-account)
- Owner or Editor role on the project (to enable APIs and create resources)

---

## Manual deployment

If you prefer to run the script directly without Cloud Shell:

```bash
git clone https://github.com/geoffscott/openclaw-deploy-to-gcp.git
cd openclaw-deploy-to-gcp

# Authenticate and set your project
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Deploy
bash deploy.sh
```

Available flags:

```
--project      PROJECT_ID     GCP project (defaults to active gcloud config)
--zone         ZONE           Compute zone (default: us-central1-a)
--name         INSTANCE       VM name (default: iap-vps)
--machine-type TYPE           Machine type (default: e2-medium)
```

The script is **idempotent** — safe to run multiple times.

---

## Connecting to your VPS

After deployment, SSH via the IAP tunnel:

```bash
gcloud compute ssh iap-vps \
  --zone=us-central1-a \
  --tunnel-through-iap
```

gcloud authenticates your Google identity through IAP before forwarding the connection. The VM has no public IP and no open port reachable from the internet.

---

## Configure OpenClaw

OpenClaw is installed automatically on first boot (takes 2-3 minutes). After SSH-ing in:

```bash
# Check the service is running
sudo systemctl status openclaw-gateway

# Watch logs
sudo journalctl -u openclaw-gateway -f

# Configure API keys and messaging platforms
sudo -u openclaw openclaw config
```

The gateway listens on `127.0.0.1:18789`. Since the VM has no public IP, the gateway is only reachable through the IAP tunnel.

---

## Architecture

```
Your machine
    │
    │  gcloud compute ssh --tunnel-through-iap
    │
    ▼
Google Identity-Aware Proxy
    │  (authenticates your Google identity)
    │  (checks roles/iap.tunnelResourceAccessor)
    │
    ▼
VM instance (no external IP)
    │  port 22 open only to 35.235.240.0/20
    │  OpenClaw gateway on 127.0.0.1:18789
    └─ Firewall denies all direct internet SSH
       Cloud NAT provides outbound-only internet
```

---

## Cleanup

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
```

---

## License

[MIT](LICENSE)
