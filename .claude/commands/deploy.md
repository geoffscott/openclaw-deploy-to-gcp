Run the OpenClaw deployment script.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. Confirm with the user before proceeding: "This will run deploy.sh against project PROJECT_ID. Continue?"
3. Run: `bash deploy.sh --project PROJECT_ID`
4. Report the result and any warnings from the health check output
