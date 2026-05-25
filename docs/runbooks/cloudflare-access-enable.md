# Cloudflare Access for approve.wind.etherport.net — enable runbook

Replaces the unadvertised Traefik public ingress + missing auth gate (L13) with **Cloudflare Tunnel + Cloudflare Access**, fronted by Google SSO. Cost: $0/mo (CF Access free tier ≤ 50 users). Sister of `infra/terraform/cloudflare/README.md`.

## What this enables

- `https://approve.wind.etherport.net/approve?id=…&token=…` becomes publicly resolvable
- Hitting that URL redirects to Google SSO → auth check → forwards to cluster
- The advisor controller can mint these URLs into emails (currently mints Tailscale-only URLs)

## Architecture at a glance

```
You click link in email
        │
        ▼
DNS lookup for approve.wind.etherport.net  ←  served by Cloudflare (post-delegation)
        │
        ▼
Cloudflare edge POP nearest you
        │
        ▼
CF Access checks your CF_Authorization cookie
   │
   ├── absent → redirect to Google SSO → returns to CF with id token
   │           → CF verifies you're in allowed_emails list
   │           → CF sets CF_Authorization cookie (24h)
   │
   └── present + valid → CF forwards request through the tunnel
                                                            │
                                                            ▼
                                                   cloudflared pods in
                                                   `cloudflared` ns
                                                            │
                                                            ▼
                                                   remediation-webhook
                                                   service (auto-remediation ns)
                                                            │
                                                            ▼
                                                   advisor controller handles
                                                   /approve handler → executes
                                                   or rejects the action
```

## Prerequisites

- `Cloudflare API (tf)` 1P item created, with token in field `token`
- `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` set as GitHub repo secrets
- Google SSO IdP added in CF Zero Trust dashboard (one-time, ~30s)

Full prereq detail in `infra/terraform/cloudflare/README.md`.

## Step-by-step

### 1. Dispatch the CF Terraform workflow (plan first)

```bash
gh workflow run terraform-cloudflare.yml -f action=plan
```

Review the plan — expect to see:
- `cloudflare_zone.wind` (created)
- `cloudflare_tunnel.wind_cluster` (created)
- `cloudflare_tunnel_config.wind_cluster` (created)
- `cloudflare_record.approve_cname` (created)
- `cloudflare_zero_trust_access_application.approve` (created)
- `cloudflare_zero_trust_access_policy.approve_allow` (created)
- `cloudflare_record.wind_existing[*]` (7 created — these are placeholders until you fill in real values from Route53)

Plan should NOT show Route53 changes (delegation is a manual step later).

### 2. Apply

```bash
gh workflow run terraform-cloudflare.yml -f action=apply
```

### 3. Get the tunnel token + populate the SOPS secret

From your laptop:

```bash
cd infra/terraform/cloudflare
terraform init -reconfigure   # ensures backend is set up locally
terraform output -raw tunnel_token | pbcopy
sops ../../../platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
# In the editor: replace REPLACE_WITH_terraform_output_-raw_tunnel_token with what's in your clipboard
# Save + exit. SOPS re-encrypts on save.
git add platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
git commit -m "cloudflared: populate tunnel token"
git push
```

### 4. Verify cloudflared comes up in the cluster

Flux reconciles within ~1min. Then:

```bash
kubectl get pods -n cloudflared
# Expect: 2/2 Running

kubectl logs -n cloudflared deploy/cloudflared --tail=20
# Look for: "Connection registered" lines (4 connections per replica = 8 total)
```

### 5. Pre-delegation sanity check

At this stage, DNS for `approve.wind.etherport.net` still answers from Route53 (no record), so the URL doesn't resolve publicly yet. To verify CF Access setup BEFORE cutting DNS:

- Visit `https://<tunnel-id>.cfargotunnel.com/approve` directly (substitute your tunnel ID from `terraform output -raw tunnel_id`). This bypasses your domain entirely. CF Access should intercept and bounce you to Google SSO.
- After successful SSO, you should land on the cloudflared-proxied origin. (The advisor `/approve` handler will respond with a 4xx for a missing token — that's fine; the path through CF Access is what we're testing.)

### 6. Cut over DNS — Route53 NS delegation

This is the destructive step. Once delegated, CF answers all `*.wind.etherport.net` queries.

First, copy current Route53 wind.* records into the CF zone with their real values. The TF module ships placeholders; replace them:

```bash
ZONE_ID=$(aws --profile homelab route53 list-hosted-zones \
  --query 'HostedZones[?Name==`etherport.net.`].Id' --output text | sed 's|/hostedzone/||')

for NAME in 'wind' '\\052.wind' 'wan1.wind' 'wan2.wind' 'ceph.wind' 'ha.wind' 'pve.wind'; do
  VAL=$(aws --profile homelab route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${NAME}.etherport.net.' && Type=='A'].ResourceRecords[*].Value" \
    --output text)
  echo "$NAME → $VAL"
done
```

Update `infra/terraform/cloudflare/variables.tf` `existing_wind_records` with these values. Re-apply:

```bash
gh workflow run terraform-cloudflare.yml -f action=apply
```

Then add the NS delegation in Route53. Edit `infra/terraform/aws/route53/records-etherport.tf` adding:

```hcl
resource "aws_route53_record" "wind_ns_delegation" {
  zone_id = aws_route53_zone.etherport.zone_id
  name    = "wind.etherport.net"
  type    = "NS"
  ttl     = 300
  records = [
    # From: terraform -chdir=../cloudflare output cf_nameservers
    "amelia.ns.cloudflare.com",  # ← replace with your actual CF nameservers
    "neville.ns.cloudflare.com",
  ]
}
```

Run the Route53 workflow:

```bash
gh workflow run terraform-route53.yml -f action=apply
```

Wait ~5min for propagation. Verify:

```bash
dig +short approve.wind.etherport.net @1.1.1.1
# Should answer with a Cloudflare-edge IP (not Route53)

dig +short ha.wind.etherport.net @1.1.1.1
# Should answer with the same A value as before (now served by CF)
```

### 7. Flip the advisor to use the public URL

```bash
# Edit:
#   platform/kubernetes/auto-remediation/deployment.yaml
# Find:
#   - name: APPROVAL_BASE_URL
#     value: "https://remediation-approve.<tailnet>.ts.net"
# Replace with:
#   - name: APPROVAL_BASE_URL
#     value: "https://approve.wind.etherport.net"

git add platform/kubernetes/auto-remediation/deployment.yaml
git commit -m "advisor: switch APPROVAL_BASE_URL to public CF-gated URL"
git push
```

Flux reconciles, controller restarts, next alert that triggers an advisor email uses the public URL.

### 8. End-to-end test

```bash
# Tail controller logs:
kubectl logs -n auto-remediation deploy/remediation-controller -f &

# Trigger any alert that would email you (or wait for one).
# Click the link in the email.
# Expect: Google SSO prompt → after auth, the advisor's /approve handler responds.

# In controller logs, look for the request landing:
# "approve handler hit: id=X token=Y action=Z"
```

## Cost summary

| Service | Cost |
|---|---|
| CF zone (Free plan) | $0/mo |
| CF Tunnel | $0/mo (any volume) |
| CF Access (≤50 users) | $0/mo |
| **Total** | **$0/mo** |

vs. the ALB+Cognito alternative (~$15-18/mo).

## Rollback

If anything breaks:

```bash
# Fastest: revert APPROVAL_BASE_URL to the Tailscale URL
# (back to pre-public state — emails route to TS-only URL again).

# Slower: remove the Route53 NS delegation
git revert <ns-delegation-commit>
git push
gh workflow run terraform-route53.yml -f action=apply
# DNS cuts back to Route53 within TTL.

# Full rollback: `terraform destroy` in infra/terraform/cloudflare
# leaves CF clean. cloudflared Deployment in cluster goes idle
# (no tunnel to connect to) but doesn't error.
```

## Operations going forward

**Adding another service behind CF Access** (e.g., Grafana at `grafana.wind.etherport.net`):

```hcl
# infra/terraform/cloudflare/main.tf — add to ingress_rule blocks:
ingress_rule {
  hostname = "grafana.wind.etherport.net"
  service  = "http://monitoring-grafana.monitoring.svc.cluster.local"
}

# Plus a CNAME record + Access app + policy resource for grafana.wind.…
```

Re-apply. New service is gated by the same CF Access policy.

## Audit / observability

- CF Access logs: Zero Trust dashboard → Logs → Access. Every authenticated request is logged with email + IP.
- cloudflared metrics: scraped by Prometheus via ServiceMonitor. Key signals:
  - `cloudflared_tunnel_active_connections` — should be 4 per replica (8 total)
  - `cloudflared_tunnel_total_requests` — request volume
  - `cloudflared_tunnel_response_status_code_total` — HTTP code distribution

Add a row to the Grafana service-status dashboard for tunnel up/down (alert if `cloudflared_tunnel_active_connections < 2` for 5min).

## DDNS Lambda migration (post-NS-delegation)

The `ddns-updater` Lambda in `infra/terraform/aws/ddns-lambda/` updates
`wan1.wind.etherport.net` and `wan2.wind.etherport.net` A records in
Route53 when home WAN IPs change. After NS delegation:

- Route53 is no longer authoritative for `*.wind.etherport.net`
- Lambda writes to Route53 still SUCCEED (zone still exists) but resolvers
  never query Route53 for wind.* → updates effectively disappear
- `wan1`/`wan2` records in CF go stale on next IP change

**Migration plan** (do after CF apply + NS delegation lands):

1. Create a CF API token scoped to `wind.etherport.net` zone DNS:Edit only
   (much tighter scope than the full TF token). Save to 1P as
   `Cloudflare DDNS token (lambda)`.

2. Add the token to AWS Secrets Manager so the Lambda can fetch it:
   ```bash
   aws --profile homelab secretsmanager create-secret \
     --name "ddns-lambda/cloudflare-token" \
     --secret-string "$(op item get 'Cloudflare DDNS token (lambda)' --fields token --reveal)"
   ```

3. Update the Lambda code in `infra/terraform/aws/ddns-lambda/lambda/handler.py`
   to write to CF API instead of Route53. The CF DNS update endpoint:
   ```
   PUT https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}
   Authorization: Bearer <token>
   ```
   Lookup record_id once via `GET /dns_records?name=wan1.wind.etherport.net`.

4. Add the Lambda IAM perm to read the new Secrets Manager secret.
   Remove the Route53 IAM perm.

5. Update Lambda env vars:
   - Remove: `HOSTED_ZONE_ID`
   - Add: `CF_ZONE_ID` (from `terraform output -raw cf_wind_zone_id` — needs to
     be added to outputs.tf)
   - Add: `CF_TOKEN_SECRET_ARN` (the Secrets Manager ARN)

6. Apply Lambda TF.

Test by manually invoking once (`aws lambda invoke …`) and verifying the
CF record updated.

**Until migration done**: wan1/wan2 records in CF are static (from
`existing_wind_records` defaults). If your WAN IPs change before migration,
update those defaults + re-apply CF TF.

