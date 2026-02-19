# GCP IAP-Only VPS + OpenClaw — One-Click Deploy

Deploy a secure virtual machine on Google Cloud with [OpenClaw](https://openclaw.ai/) pre-installed. The VM is **only accessible through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)** — no public IP address, no SSH port open to the internet. Access is gated entirely by your Google identity.

Secrets (API keys, bot tokens) are stored in **GCP Secret Manager** and injected into the OpenClaw process at startup — never written to persistent disk.

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
| **Secret Manager** | One secret per key (e.g. `ANTHROPIC_API_KEY`); all enumerated at service start, stored only in RAM |
| **VM service account** | `iap-vps-vm-sa` with `secretmanager.secretAccessor` + `secretmanager.viewer` |
| **Cloud NAT** | Outbound-only internet for the private VM (package downloads, API calls) |
| **Cloud Router** | Required by Cloud NAT |
| **Firewall (allow)** | SSH (`tcp:22`) from IAP range `35.235.240.0/20` only |
| **Firewall (deny)** | Direct SSH from `0.0.0.0/0` blocked |
| **OS Login** | Enabled — SSH keys managed via IAM |
| **IAM binding** | Deploying user receives `roles/iap.tunnelResourceAccessor` |

APIs enabled automatically: `compute.googleapis.com`, `iap.googleapis.com`, `secretmanager.googleapis.com`, `iam.googleapis.com`

---

## Prerequisites

- A **dedicated GCP project** with [billing enabled](https://cloud.google.com/billing/docs/how-to/manage-billing-account) — the VM loads *every* secret in the project as an environment variable, so this project should not be shared with other workloads
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

## Accessing the OpenClaw Web UI

The OpenClaw gateway runs on `localhost:18789` inside the VM. To access the web UI from your browser, forward the port through the IAP SSH tunnel:

```bash
gcloud compute ssh iap-vps \
  --zone=us-central1-a \
  --tunnel-through-iap \
  -- -L 18789:localhost:18789
```

Then open [http://localhost:18789](http://localhost:18789) in your browser. The tunnel stays open as long as the SSH session is active.

**How this works:** The `-L 18789:localhost:18789` flag tells SSH to listen on port 18789 on your machine and forward traffic through the IAP tunnel to port 18789 on the VM. Your browser talks to `localhost`, SSH encrypts and routes it through IAP (which verifies your Google identity), and it arrives at the OpenClaw gateway. No port is opened on the VM — the same zero-public-surface architecture applies.

**Tip:** If port 18789 is already in use on your machine, pick a different local port:

```bash
gcloud compute ssh iap-vps \
  --zone=us-central1-a \
  --tunnel-through-iap \
  -- -L 8080:localhost:18789
```

Then open [http://localhost:8080](http://localhost:8080) instead.

---

## Secrets management

Each secret in the GCP project becomes an environment variable for OpenClaw. Create one secret per key — the VM enumerates all secrets at startup and assembles them into `/run/openclaw/env` (tmpfs — RAM-backed, never on persistent disk). The systemd unit loads this file via `EnvironmentFile`.

> **Important:** This project should be dedicated to this deployment. All secrets in the project are loaded into the OpenClaw process.

### Required secrets

| Secret | Value | How to obtain |
|--------|-------|---------------|
| `ANTHROPIC_API_KEY` | Anthropic API key (`sk-ant-...`) | [Anthropic Console](https://console.anthropic.com/) → API Keys |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway device token | SSH into the VM and run `sudo -u openclaw openclaw setup` — the token is printed at the end of the interactive setup. Store it as a secret so it persists across reboots (the VM's credential paths are RAM-backed). |

#### Option A — CLI

```bash
# 1. SSH in and run setup to get the gateway token
gcloud compute ssh iap-vps --zone=us-central1-a --tunnel-through-iap
sudo -u openclaw openclaw setup
# Copy the token printed at the end

# 2. Store as secrets
gcloud secrets create ANTHROPIC_API_KEY --project=YOUR_PROJECT_ID --data-file=- <<< 'sk-ant-...'
gcloud secrets create OPENCLAW_GATEWAY_TOKEN --project=YOUR_PROJECT_ID --data-file=- <<< '<token-from-setup>'

# 3. Restart to pick up new secrets
gcloud compute ssh iap-vps --tunnel-through-iap \
  -- sudo systemctl restart openclaw-gateway
```

#### Option B — GCP Console UI

1. Open [Secret Manager](https://console.cloud.google.com/security/secret-manager) in the GCP Console
2. Click **Create Secret**
3. Set **Name** to `ANTHROPIC_API_KEY` and paste your API key as the **Secret value**
4. Click **Create Secret**
5. Repeat for `OPENCLAW_GATEWAY_TOKEN` (paste the token from `openclaw setup`)
6. Restart the gateway to pick up the new secrets:
   ```bash
   gcloud compute ssh iap-vps --tunnel-through-iap \
     -- sudo systemctl restart openclaw-gateway
   ```

### Optional secrets

Add these as needed for your integrations:

| Secret | Value | Notes |
|--------|-------|-------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (`123456:ABC-DEF...`) | From [@BotFather](https://t.me/BotFather) |
| `SLACK_BOT_TOKEN` | Slack bot token (`xoxb-...`) | From Slack app settings |
| `SLACK_APP_TOKEN` | Slack app-level token (`xapp-...`) | Required for Socket Mode (no public URL needed) |

> **Note:** This VM has no public IP, so Slack must use **Socket Mode** (the default). Socket Mode requires a `SLACK_APP_TOKEN` (`xapp-...`) — do not use `SLACK_SIGNING_SECRET`, which is for HTTP Events API mode and requires a publicly reachable URL.

### Update an existing secret

**CLI:**

```bash
gcloud secrets versions add ANTHROPIC_API_KEY \
  --project=YOUR_PROJECT_ID \
  --data-file=- <<< 'sk-ant-new-key...'
```

**Console UI:** Open [Secret Manager](https://console.cloud.google.com/security/secret-manager), click the secret name, then **New Version**, paste the new value, and click **Add New Version**.

Then restart the service to pick up the change (no reboot needed):

```bash
gcloud compute ssh iap-vps --tunnel-through-iap \
  -- sudo systemctl restart openclaw-gateway
```

### What's protected

| Path | Protection |
|------|-----------|
| `/run/openclaw/env` | tmpfs (RAM) — secrets never touch persistent disk |
| `~/.openclaw/credentials/` | Bind-mounted to tmpfs — any writes stay in RAM |
| `~/.openclaw/.env` | Symlinked to `/dev/null` — writes discarded |

---

## Configure OpenClaw

OpenClaw is installed automatically on first boot (takes 2-3 minutes). After SSH-ing in:

```bash
# Check the service is running
sudo systemctl status openclaw-gateway

# Watch logs
sudo journalctl -u openclaw-gateway -f
```

The gateway listens on `127.0.0.1:18789`. Since the VM has no public IP, the gateway is only reachable through the IAP tunnel.

---

## Architecture

```
Your machine
    │
    │  gcloud compute ssh --tunnel-through-iap -- -L 18789:localhost:18789
    │
    ├─ SSH terminal session
    │
    ├─ Browser → http://localhost:18789
    │       (port-forwarded through the same IAP tunnel)
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
    │  Secrets from Secret Manager → tmpfs (RAM only)
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

# Delete all secrets
for SECRET in $(gcloud secrets list --project=YOUR_PROJECT_ID --format="value(name)"); do
  gcloud secrets delete "${SECRET}" --project=YOUR_PROJECT_ID --quiet
done

# Delete VM service account
gcloud iam service-accounts delete iap-vps-vm-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com --quiet
```

---

## License

[MIT](LICENSE)
