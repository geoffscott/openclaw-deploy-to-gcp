# Backlog

## Web UI Access — Future Options

The current approach uses SSH port forwarding through IAP (Option A) to access
the OpenClaw web UI. The following options provide shared/team-friendly access
and should be evaluated when the need arises.

### Option B — IAP-Protected HTTPS Load Balancer

Put an HTTPS load balancer in front of the VM with IAP enabled on the backend
service. IAP handles authentication (Google identity + MFA) and the web UI is
never directly exposed to the internet.

**What this involves:**

- Reserve a static IP and create a managed SSL certificate
- Create an instance group (unmanaged, single instance) for the VM
- Create a backend service with IAP enabled
- Create a URL map, target HTTPS proxy, and forwarding rule
- Configure an OAuth consent screen and credentials for IAP
- Grant `roles/iap.httpsResourceAccessor` to authorized users

**When to use:** When the team needs shared browser access to the web UI without
each person running their own SSH tunnel. Good for dashboards and demos.

**SOC 2 notes:** IAP provides Google identity verification, MFA support, audit
logging via Cloud Audit Logs, and context-aware access policies (device posture,
IP range). This satisfies CC6.1, CC6.6, and CC7.1 controls.

### Option C — VPN / BeyondCorp Enterprise

Route web UI traffic through an existing corporate VPN or Google BeyondCorp
Enterprise setup instead of opening a public port.

**What this involves:**

- Configure Cloud VPN or BeyondCorp Enterprise connector
- Set up access policies tied to the corporate identity provider
- Route traffic from the VPN to the VM's private IP on port 18789

**When to use:** When the organization already has a VPN or BeyondCorp
deployment and wants to consolidate access through a single control plane.

**SOC 2 notes:** Inherits the access controls, MFA, and audit logging of the
existing VPN/BeyondCorp infrastructure. No additional public surface.

---

## Secrets Management — Future Options

### Per-Secret IAM Restrictions

Currently the VM service account has project-level `secretmanager.secretAccessor`
and `secretmanager.viewer`, meaning it can read all secrets in the project. Since
the project is dedicated to this deployment, this is fine.

If future requirements demand finer-grained access (e.g., certain secrets readable
only by specific services), consider:

- IAM conditions scoped to individual secret resource names
- Separate service accounts per service, each with access to only its secrets
- Secret Manager labels + IAM conditions to group secrets by access tier

This would require changes to the fetch script (filtering by label or explicit list)
and deploy.sh (per-secret IAM bindings instead of project-level).
