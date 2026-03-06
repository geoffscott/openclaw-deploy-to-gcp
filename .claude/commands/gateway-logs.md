Show recent OpenClaw gateway logs from the VM.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. Run: `gcloud compute ssh iap-vps --zone=us-central1-a --tunnel-through-iap --project=PROJECT_ID -- "sudo journalctl -u openclaw-gateway -n 50 --no-pager"`
3. Show the output. If the user asks about a specific topic (e.g. "discord errors"), grep the logs for relevant terms.
