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
  logging.googleapis.com \
  monitoring.googleapis.com \
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

`deploy.sh` automatically creates all secrets. Required and gateway secrets get
an initial version; optional provider and channel secrets are created as empty
resources (no version). Add a version to activate an optional secret.

### Pre-created secrets

| Secret | Category | Initial value |
|--------|----------|---------------|
| `ANTHROPIC_API_KEY` | **Required** | `REPLACE_ME` |
| `OPENAI_API_KEY` | Provider | *(no version)* |
| `OPENROUTER_API_KEY` | Provider | *(no version)* |
| `GEMINI_API_KEY` | Provider | *(no version)* |
| `XAI_API_KEY` | Provider | *(no version)* |
| `GROQ_API_KEY` | Provider | *(no version)* |
| `MISTRAL_API_KEY` | Provider | *(no version)* |
| `DEEPGRAM_API_KEY` | Provider | *(no version)* |
| `TELEGRAM_BOT_TOKEN` | Channel | *(no version)* |
| `DISCORD_BOT_TOKEN` | Channel | *(no version)* |
| `SLACK_BOT_TOKEN` | Channel | *(no version)* |
| `SLACK_APP_TOKEN` | Channel | *(no version)* |
| `GITHUB_TOKEN` | GitHub | *(no version)* |
| `GITHUB_USERNAME` | GitHub | *(no version)* |
| `GITHUB_EMAIL` | GitHub | *(no version)* |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway | Auto-generated (hex) |
| `OPENCLAW_PRIMARY_MODEL` | Gateway | `claude-haiku-4-5-20251001` |

Secrets without versions are ignored until the user adds a value with
`gcloud secrets versions add`.

```bash
# Update a required secret
gcloud secrets versions add ANTHROPIC_API_KEY \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'sk-ant-api03-...'

# Enable a channel
gcloud secrets versions add TELEGRAM_BOT_TOKEN \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< '123456:ABC-...'

# Restart service to pick up new secrets
gcloud compute ssh iap-vps --zone=us-central1-a \
  --tunnel-through-iap --project="${GCP_PROJECT_ID}" \
  -- sudo systemctl restart openclaw-gateway
```

### Multi-agent channel setup

To run multiple agents, each connected to a different Discord/Telegram/Slack
server, create additional bot token secrets using the naming convention:

```
DISCORD_BOT_TOKEN_AGENTNAME
TELEGRAM_BOT_TOKEN_AGENTNAME
SLACK_BOT_TOKEN_AGENTNAME
```

The startup script uses prefix matching — any secret starting with
`DISCORD_BOT_TOKEN` (including `DISCORD_BOT_TOKEN_ANANDA`) auto-enables the
Discord plugin. The same applies to Telegram and Slack prefixes.

After adding the secret, SSH into the VM and register the account + routing:

```bash
# 1. Register the channel account
sudo -u openclaw openclaw channels add \
  --channel discord --account agentname --token 'the-bot-token'

# 2. Set up routing (maps channel account → agent)
sudo -u openclaw openclaw config set bindings '[
  {"agentId":"main","match":{"channel":"discord","accountId":"main"}},
  {"agentId":"agentname","match":{"channel":"discord","accountId":"agentname"}}
]' --json

# 3. Restart to apply
sudo systemctl restart openclaw-gateway

# 4. Verify
sudo -u openclaw openclaw agents list --bindings
sudo -u openclaw openclaw channels list
```

### GitHub integration

When `GITHUB_TOKEN`, `GITHUB_USERNAME`, and `GITHUB_EMAIL` secrets have values,
the startup script automatically configures git and the GitHub CLI (`gh`) for the
`openclaw` user. This enables agents to clone repos, create branches, and submit
pull requests.

```bash
# Add GitHub credentials
gcloud secrets versions add GITHUB_TOKEN \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'ghp_...'

gcloud secrets versions add GITHUB_USERNAME \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'your-username'

gcloud secrets versions add GITHUB_EMAIL \
  --project="${GCP_PROJECT_ID}" \
  --data-file=- <<< 'you@example.com'

# Restart to pick up credentials
gcloud compute ssh iap-vps --zone=us-central1-a \
  --tunnel-through-iap --project="${GCP_PROJECT_ID}" \
  -- sudo systemctl restart openclaw-gateway
```

### Claude models

The startup script seeds all available Claude models on first provision:

| Model | ID |
|-------|----|
| Haiku 4.5 (default) | `anthropic/claude-haiku-4-5-20251001` |
| Sonnet 4.6 | `anthropic/claude-sonnet-4-6` |
| Opus 4.6 | `anthropic/claude-opus-4-6` |

The default model is Haiku 4.5 to keep costs low. Change per-agent or globally:

```bash
# Change default for all agents
sudo -u openclaw openclaw config set agents.defaults.model.primary \
  "anthropic/claude-sonnet-4-6"

# Change for a specific agent (via the web UI or config)
```

### Agent sandboxing

By default, agents are provisioned with sandbox mode enabled and restricted
tool access:

| Setting | Default | Effect |
|---------|---------|--------|
| `agents.defaults.sandbox.mode` | `all` | All agent sessions run in Docker containers |
| `agents.defaults.sandbox.docker.network` | `bridge` | Containers have internet access (for GitHub, web, APIs) |
| `tools.elevated.enabled` | `false` | Agents cannot use elevated/admin tools |
| `tools.fs.workspaceOnly` | `true` | Filesystem access limited to agent workspace |

The startup script builds a custom `openclaw-sandbox:bookworm-slim` Docker image
with common dev tools pre-installed: `curl`, `wget`, `git`, `jq`, `python3`, and
`gh` (GitHub CLI). To customise the image, edit the `SANDBOX_DOCKERFILE` heredoc
in `startup.sh` and rebuild:

```bash
# Rebuild manually (or reboot the VM to trigger startup.sh)
sudo docker build -t openclaw-sandbox:bookworm-slim - <<'EOF'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq curl wget git jq python3 gh
EOF
sudo -u openclaw openclaw sandbox recreate --all --force
```

This prevents agents from modifying gateway config, accessing other agents'
data, or running arbitrary commands on the host. To grant an agent elevated
access (e.g., for admin tasks), override per-agent:

```bash
# Grant elevated tools to a specific agent
sudo -u openclaw openclaw config set \
  'agents.list[0].tools.elevated.enabled' true
```

Gateway administration (restarts, config changes, secret management) should
be performed from the CLI on your local machine, not by agents.

### Credential isolation on the VM

| Path | Protection |
|------|-----------|
| `/run/openclaw/env` | tmpfs — secrets exist only in RAM |
| `~/.openclaw/credentials/` | Restricted permissions (persists device tokens) |
| `~/.openclaw/.env` | Symlinked to `/dev/null` |

### Runtime security hardening

| Layer | Mechanism |
|-------|-----------|
| Metadata server | iptables blocks `openclaw` user from `169.254.169.254` (prevents token theft) |
| OAuth scopes | `cloud-platform` (required by Secret Manager; access limited by SA's IAM roles to secrets + logging + monitoring only) |
| Systemd sandbox | `ProtectSystem=strict`, `NoNewPrivileges`, `CapabilityBoundingSet=` (empty), syscall filtering |
| Network | Port 18789 denied at firewall; SSH only via IAP (priority 500) |
| OS patching | `unattended-upgrades` with automatic reboot at 04:00 |
| Audit trail | Cloud Ops Agent forwards journal + syslog + auth.log to Cloud Logging |
| Secret parsing | `jq` for JSON; values sanitized (newlines stripped) to prevent env injection |

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
  --filter="name:(compute.googleapis.com OR iap.googleapis.com OR secretmanager.googleapis.com OR logging.googleapis.com OR monitoring.googleapis.com)" \
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
gcloud compute firewall-rules delete allow-iap-ssh allow-iap-ssh-deny-public iap-vps-deny-openclaw-port \
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
