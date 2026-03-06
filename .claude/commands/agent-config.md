Show the current OpenClaw agent and channel configuration on the VM.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. Run these in parallel via IAP SSH to the VM (`iap-vps`, zone `us-central1-a`):
   - `sudo -u openclaw openclaw config get agents` (agent definitions and defaults)
   - `sudo -u openclaw openclaw config get channels` (channel config)
   - `sudo -u openclaw openclaw config get bindings` (routing bindings)
3. Present a clear summary of:
   - Each agent (name, identity, model, workspace)
   - Each channel account (channel type, account name, enabled status)
   - Routing: which channel account maps to which agent
