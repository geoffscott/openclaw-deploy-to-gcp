Help the user add or update a secret in GCP Secret Manager for the OpenClaw deployment.

IMPORTANT: Never ask for or handle secret values directly. Secret values should never flow through this conversation.

Steps:
1. Determine the GCP project ID from `gcloud config get-value project` or `$GCP_PROJECT_ID`
2. List current secrets and their status:
   `gcloud secrets list --project=PROJECT_ID --format="table(name)"`
   For each secret, check if it has versions:
   `gcloud secrets versions list SECRET_NAME --project=PROJECT_ID --format="value(name)" --limit=1`
3. Ask the user which secret they want to update (or if they want to create a new one)
4. Provide a direct link to the Secret Manager console for that secret:
   `https://console.cloud.google.com/security/secret-manager/secret/SECRET_NAME/versions?project=PROJECT_ID`
5. Remind the user to restart the gateway after updating:
   "After adding the secret value, run /restart-gateway to pick up the change."
