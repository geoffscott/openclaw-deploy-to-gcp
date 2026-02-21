# GCP IAP-Only VPS + OpenClaw — One-Click Deploy

Deploy a secure virtual machine on Google Cloud with [OpenClaw](https://openclaw.ai/) pre-installed. The VM is **only accessible through [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)** — no public IP address, no SSH port open to the internet. Access is gated entirely by your Google identity.

Secrets (API keys, bot tokens) are stored in **GCP Secret Manager** and injected into the OpenClaw process at startup — never written to persistent disk.

---

## Deploy to GCP

Click the button below to open this repo in Cloud Shell and follow the interactive tutorial:

[![Deploy to GCP](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/geoffscott/openclaw-deploy-to-gcp&cloudshell_tutorial=cloudshell_tutorial.md)

The tutorial will walk you through:

1. **Select your project** — pick (or create) a dedicated GCP project
2. **Run the deploy script** — creates the VM, firewall, NAT, and secrets
3. **Add your API key** — update the `ANTHROPIC_API_KEY` secret with your real key
4. **Access the Web UI** — port-forward through the IAP tunnel and open it in your browser

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

The deploy script pre-creates all secrets with placeholder values. You just need to update the ones you want to use.

| Secret | Value | How to obtain |
|--------|-------|---------------|
| `ANTHROPIC_API_KEY` | Anthropic API key (`sk-ant-...`) | [Anthropic Console](https://console.anthropic.com/) → API Keys |

> **Note:** `OPENCLAW_GATEWAY_TOKEN` is auto-generated during deployment — you don't need to set it manually. If you want to run the full interactive setup wizard instead, SSH in and run `sudo -u openclaw openclaw setup`, then update the secret with the token it prints.

#### Option A — CLI

```bash
# Update your API key (the secret already exists with a placeholder)
gcloud secrets versions add ANTHROPIC_API_KEY \
  --project=YOUR_PROJECT_ID \
  --data-file=- <<< 'sk-ant-...'

# Restart to pick up the new secret
gcloud compute ssh iap-vps --tunnel-through-iap \
  -- sudo systemctl restart openclaw-gateway
```

#### Option B — GCP Console UI

1. Open [Secret Manager](https://console.cloud.google.com/security/secret-manager) in the GCP Console
2. Click `ANTHROPIC_API_KEY` → **New Version**
3. Paste your API key and click **Add New Version**
4. Restart the gateway to pick up the new secret:
   ```bash
   gcloud compute ssh iap-vps --tunnel-through-iap \
     -- sudo systemctl restart openclaw-gateway
   ```

### Optional secrets

These are also pre-created with `DISABLED` as the value. Update the ones you need:

| Secret | Value | Notes |
|--------|-------|-------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot token (`123456:ABC-DEF...`) | From [@BotFather](https://t.me/BotFather) |
| `SLACK_BOT_TOKEN` | Slack bot token (`xoxb-...`) | See [Slack setup](#slack-setup) below |
| `SLACK_APP_TOKEN` | Slack app-level token (`xapp-...`) | See [Slack setup](#slack-setup) below |
| `DISCORD_BOT_TOKEN` | Discord bot token | From [Discord Developer Portal](https://discord.com/developers/applications) |
| `OPENAI_API_KEY` | OpenAI API key | From [OpenAI Platform](https://platform.openai.com/api-keys) |
| `OPENROUTER_API_KEY` | OpenRouter API key | From [OpenRouter](https://openrouter.ai/keys) |
| `GEMINI_API_KEY` | Google Gemini API key | From [Google AI Studio](https://aistudio.google.com/apikey) |
| `XAI_API_KEY` | xAI API key | From [xAI Console](https://console.x.ai/) |
| `GROQ_API_KEY` | Groq API key | From [Groq Console](https://console.groq.com/keys) |
| `MISTRAL_API_KEY` | Mistral API key | From [Mistral Console](https://console.mistral.ai/api-keys) |
| `DEEPGRAM_API_KEY` | Deepgram API key | From [Deepgram Console](https://console.deepgram.com/) |

```bash
# Example: enable Telegram
gcloud secrets versions add TELEGRAM_BOT_TOKEN \
  --project=YOUR_PROJECT_ID \
  --data-file=- <<< '123456:ABC-DEF...'
```

### Slack setup

This VM has no public IP, so Slack must use **Socket Mode** — a WebSocket connection initiated from the VM, requiring no inbound URL. This needs two tokens: a **Bot Token** (`xoxb-...`) and an **App-Level Token** (`xapp-...`).

#### 1. Create a Slack app

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App** → **From scratch**
2. Name your app (e.g. "OpenClaw") and select your workspace

#### 2. Enable Socket Mode

1. In the left sidebar, go to **Socket Mode**
2. Toggle **Enable Socket Mode** to on
3. You'll be prompted to create an app-level token — name it anything (e.g. "socket") and add the **`connections:write`** scope
4. Click **Generate** — copy the `xapp-...` token → this is your `SLACK_APP_TOKEN`

#### 3. Configure bot permissions

1. In the left sidebar, go to **OAuth & Permissions**
2. Under **Scopes → Bot Token Scopes**, add at minimum:
   - `app_mentions:read` — so the bot can see when it's @mentioned
   - `chat:write` — so the bot can send messages
   - `im:history` — so the bot can read DMs
   - `im:read` — so the bot can see DM conversations
   - `im:write` — so the bot can open DMs
3. If you want the bot to participate in channels (not just DMs), also add:
   - `channels:history` — read messages in public channels
   - `channels:read` — see public channel metadata
   - `groups:history` — read messages in private channels

#### 4. Enable Events

1. In the left sidebar, go to **Event Subscriptions**
2. Toggle **Enable Events** to on
3. Under **Subscribe to bot events**, add:
   - `app_mention` — triggers when someone @mentions the bot
   - `message.im` — triggers on direct messages to the bot
4. Click **Save Changes**

#### 5. Install and get the bot token

1. In the left sidebar, go to **Install App**
2. Click **Install to Workspace** and authorize
3. Copy the **Bot User OAuth Token** (`xoxb-...`) → this is your `SLACK_BOT_TOKEN`

#### 6. Add the tokens to Secret Manager

```bash
gcloud secrets versions add SLACK_BOT_TOKEN \
  --project=YOUR_PROJECT_ID \
  --data-file=- <<< 'xoxb-your-token'

gcloud secrets versions add SLACK_APP_TOKEN \
  --project=YOUR_PROJECT_ID \
  --data-file=- <<< 'xapp-your-token'

# Restart to pick up the new secrets
gcloud compute ssh iap-vps --tunnel-through-iap \
  -- sudo systemctl restart openclaw-gateway
```

> **Do not** use `SLACK_SIGNING_SECRET` — that's for HTTP Events API mode which requires a publicly reachable URL. Socket Mode uses the `SLACK_APP_TOKEN` instead.

#### 7. Connect through the Web UI

Once the service restarts with your Slack tokens, open the OpenClaw web UI to verify the connection and manage channel settings.

1. Start a port-forwarding tunnel (if you don't already have one open):
   ```bash
   gcloud compute ssh iap-vps \
     --zone=us-central1-a \
     --tunnel-through-iap \
     -- -L 18789:localhost:18789
   ```
2. Open [http://localhost:18789](http://localhost:18789) in your browser
3. On first visit you'll see **"pairing required"** — enter your **Gateway Token** on the Overview page and click **Connect**
   - Your gateway token was auto-generated during deployment. Retrieve it with:
     ```bash
     gcloud secrets versions access latest \
       --secret=OPENCLAW_GATEWAY_TOKEN \
       --project=YOUR_PROJECT_ID
     ```
   - You can also append it to the URL: `http://localhost:18789?token=YOUR_GATEWAY_TOKEN`
4. Once connected (green status indicator), navigate to **Settings → Config** — you should see Slack listed as a connected channel

The Slack channel connects automatically via Socket Mode using the tokens you set as environment variables. No additional configuration is needed in the web UI unless you want to fine-tune settings like DM policy or channel allowlists.

#### 8. Approve users (DM pairing)

OpenClaw defaults to **pairing mode** for Slack DMs — when someone DMs your bot for the first time, they receive a short-lived pairing code and the bot won't respond until you approve it. This prevents strangers from using your bot.

**From the Web UI:**

1. A user DMs your bot in Slack and receives a message like: *"Your pairing code is: `GHI789`"*
2. The user tells you the code
3. In the OpenClaw Web UI chat, type: **"Approve Slack pairing code GHI789"**
4. The user can now chat with the bot

**From the terminal (via SSH):**

```bash
gcloud compute ssh iap-vps --tunnel-through-iap -- \
  sudo -u openclaw openclaw pairing approve slack GHI789
```

**Useful pairing commands:**

```bash
# List pending and approved pairing codes
gcloud compute ssh iap-vps --tunnel-through-iap -- \
  sudo -u openclaw openclaw pairing list slack

# Check for risky DM policy configurations
gcloud compute ssh iap-vps --tunnel-through-iap -- \
  sudo -u openclaw openclaw doctor
```

Pairing codes expire after about 1 hour. If a code expires, have the user DM the bot again to get a fresh one. Each approved user gets their own isolated conversation context.

### Update a secret

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

## Contributing

This repo is designed to be developed with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). The session-start hook (`.claude/hooks/session-start.sh`) automatically installs `gcloud` and authenticates with GCP when running in a cloud session.

### Developer environment setup

1. **Create a dedicated GCP project** (or reuse an existing one) with billing enabled.

2. **Create a deployer service account** and grant it the required roles:

   ```bash
   gcloud iam service-accounts create openclaw-deployer \
     --display-name="OpenClaw Deployer" \
     --project=YOUR_PROJECT_ID

   for ROLE in roles/compute.admin roles/iam.securityAdmin \
               roles/serviceusage.serviceUsageAdmin \
               roles/iam.serviceAccountAdmin roles/secretmanager.admin; do
     gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
       --member="serviceAccount:openclaw-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
       --role="${ROLE}"
   done
   ```

3. **Download the key and base64-encode it:**

   ```bash
   gcloud iam service-accounts keys create key.json \
     --iam-account="openclaw-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com"

   base64 -w 0 key.json
   # Copy the output — this is your GCP_SERVICE_ACCOUNT_KEY value
   rm key.json
   ```

4. **Add both secrets** to your Claude Code environment settings (Settings > Environment Variables > Secrets):

   | Secret name | Value |
   |-------------|-------|
   | `GCP_SERVICE_ACCOUNT_KEY` | The base64-encoded JSON key from step 3 |
   | `GCP_PROJECT_ID` | Your GCP project ID (e.g. `my-project-123`) |

   The session-start hook reads these on every cloud session to authenticate `gcloud` automatically.

5. **Enable required APIs** (if the deployer SA cannot enable them itself):

   ```bash
   gcloud services enable \
     compute.googleapis.com \
     iap.googleapis.com \
     secretmanager.googleapis.com \
     iam.googleapis.com \
     --project=YOUR_PROJECT_ID
   ```

### How it works

When Claude Code starts a cloud session, the hook at `.claude/hooks/session-start.sh`:

1. Installs the Google Cloud SDK (downloaded from GCS, not `sdk.cloud.google.com`)
2. Decodes `GCP_SERVICE_ACCOUNT_KEY` from base64 to a temporary JSON file
3. Runs `gcloud auth activate-service-account` with the key
4. Sets the default project from `GCP_PROJECT_ID`
5. Cleans up the temporary key file

The deploy script (`deploy.sh`) then runs using the authenticated service account. It also creates a separate VM service account (`iap-vps-vm-sa`) at runtime for Secret Manager access — this is distinct from the deployer SA.

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
