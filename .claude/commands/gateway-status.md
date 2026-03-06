Check the health and status of the OpenClaw gateway on the VM.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. Run these in parallel via IAP SSH to the VM (`iap-vps`, zone `us-central1-a`):
   - `sudo systemctl status openclaw-gateway | head -20` (service status)
   - `sudo -u openclaw openclaw channels list` (channel accounts)
   - `sudo -u openclaw openclaw agents list --bindings` (agent routing)
3. Report a summary: service state, uptime, connected channels, agent bindings
