# GCP IAP-Only VPS — One-Click Deploy

Deploy a secure virtual machine on Google Cloud that is **only accessible through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)**. No public IP address. No SSH port open to the internet. Access is gated entirely by your Google identity.

---

## Deploy to GCP

Click the button below to open this repo in Cloud Shell and follow the interactive tutorial:

[![Deploy to GCP](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/geoffscott/openclaw-deploy-to-gcp&cloudshell_tutorial=cloudshell_tutorial.md)

---

## What gets deployed

| Resource | Details |
|----------|---------|
| **VM instance** | `e2-micro`, Debian 12, Shielded VM, **no external IP** |
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
--project PROJECT_ID   GCP project (defaults to active gcloud config)
--zone    ZONE         Compute zone (default: us-central1-a)
--name    INSTANCE     VM name (default: iap-vps)
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
    └─ Firewall denies all direct internet SSH
```

---

## Cleanup

```bash
gcloud compute instances delete iap-vps --zone=us-central1-a --quiet
gcloud compute firewall-rules delete allow-iap-ssh --quiet
gcloud compute firewall-rules delete allow-iap-ssh-deny-public --quiet
```

---

## License

[MIT](LICENSE)
