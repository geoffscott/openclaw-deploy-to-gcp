Restart the OpenClaw gateway service on the VM.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. Run: `gcloud compute ssh iap-vps --zone=us-central1-a --tunnel-through-iap --project=PROJECT_ID -- "sudo systemctl restart openclaw-gateway"`
3. Wait a few seconds, then verify it started: `gcloud compute ssh iap-vps --zone=us-central1-a --tunnel-through-iap --project=PROJECT_ID -- "sudo systemctl status openclaw-gateway | head -15"`
4. Report the result (active/failed, uptime)
