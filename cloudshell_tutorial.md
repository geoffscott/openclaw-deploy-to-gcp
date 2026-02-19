# Deploy an IAP-Only VPS on GCP

This tutorial walks you through deploying a secure virtual machine that is **only reachable through Google's [Identity-Aware Proxy (IAP)](https://cloud.google.com/iap)** — no public IP, no open SSH port on the internet.

---

## Step 1 — Select your project

Make sure you are working in the right GCP project.

```bash
gcloud config set project <YOUR_PROJECT_ID>
```

You can list your projects with:

```bash
gcloud projects list
```

Click **Next** when ready.

---

## Step 2 — Review the deployment script

Open <walkthrough-editor-open-file filePath="deploy.sh">deploy.sh</walkthrough-editor-open-file> to review what the script does before running it.

Key actions performed by the script:

| Step | What happens |
|------|-------------|
| Enable APIs | `compute.googleapis.com` and `iap.googleapis.com` |
| Firewall (allow) | SSH (`tcp:22`) from IAP range `35.235.240.0/20` only |
| Firewall (deny) | Direct SSH from `0.0.0.0/0` blocked |
| VM creation | No external IP, OS Login enabled, Shielded VM |
| IAM binding | Grants your account `roles/iap.tunnelResourceAccessor` |

---

## Step 3 — Run the deploy script

Run the deployment with default settings:

```bash
bash deploy.sh
```

Or customise it:

```bash
bash deploy.sh --name my-vps --zone europe-west1-b
```

Available flags:

| Flag | Default | Description |
|------|---------|-------------|
| `--project` | current gcloud project | GCP project ID |
| `--zone` | `us-central1-a` | Compute zone |
| `--name` | `iap-vps` | VM instance name |

The script is **idempotent** — safe to run multiple times.

---

## Step 4 — Connect to your VPS

Once deployment finishes, SSH into the instance through IAP:

```bash
gcloud compute ssh iap-vps \
  --zone=us-central1-a \
  --tunnel-through-iap
```

Replace `iap-vps` and `us-central1-a` with your chosen instance name and zone if you used custom values.

> **How it works:** gcloud opens an encrypted tunnel to Google's IAP service, which authenticates your identity before forwarding traffic to the VM. The VM never exposes port 22 to the public internet.

---

## Step 5 — Verify access control

Confirm the instance has no external IP:

```bash
gcloud compute instances describe iap-vps \
  --zone=us-central1-a \
  --format="get(networkInterfaces[0].accessConfigs)"
```

The output should be empty — no `natIP` means no public address.

---

## Cleanup

To tear down all resources created by this deployment:

```bash
# Delete the VM
gcloud compute instances delete iap-vps --zone=us-central1-a --quiet

# Delete firewall rules
gcloud compute firewall-rules delete allow-iap-ssh --quiet
gcloud compute firewall-rules delete allow-iap-ssh-deny-public --quiet
```

---

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

**Deployment complete!** Your VPS is running with IAP-only access — no exposed ports, no public IP.
