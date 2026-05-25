# Cloudflare full-zone migration + Access for approve.wind.etherport.net

Migrates etherport.net DNS from Route53 to Cloudflare, then puts CF Access (Google SSO) in front of the AI advisor approval URL. Cost stays $0/mo; saves ~$15-18/mo if you later drop the ALB by tunneling its services through CF.

**Email is priority-1.** SES sending (alertmanager, advisor, daily reports) depends on SPF + DKIM + DMARC + MX records being preserved exactly. Test a real send post-cutover before declaring success.

## Architecture after migration

```
PUBLIC DNS                                            INTERNAL
─────────                                             ────────
etherport.net  ← CF (Free plan, full zone)            aws.etherport.net
  *.wind, ha.wind, wan1/2.wind, vpn-*,                ← Route53 PRIVATE zone
  email TXT/MX, ACME CNAMEs, sinkholes                  (VPC-internal, unchanged)
                ↓
        CF Tunnel (cloudflared)
                ↓
            in-cluster
```

## Prerequisites

Per `infra/terraform/cloudflare/README.md` — CF zone manually added, API token + secrets configured, Google SSO IdP added, Zone ID captured.

## Step-by-step

### Phase A — pre-cutover (CF zone authoritative for nothing yet)

#### 1. Plan

```bash
gh workflow run terraform-cloudflare.yml -f action=plan
```

Expect ~24 created resources:
- 7 A records (wan1/2.wind, wind apex, vpn-use1/usw2, ceph/pve sinkholes)
- 8 CNAME records (3 DKIM, 3 ACME, ha.wind, *.wind)
- 1 MX (mail)
- 2 TXT (SPF + DMARC)
- 1 tunnel + tunnel config + approve CNAME
- 1 Access app + policy
- 1 Service token (alexa)

Verify no `cloudflare_zone.etherport` create — should show as already in state (imported in setup).

#### 2. Apply

```bash
gh workflow run terraform-cloudflare.yml -f action=apply
```

#### 3. Populate cloudflared token + re-enable in Flux

```bash
cd infra/terraform/cloudflare
terraform init -reconfigure
terraform output -raw tunnel_token | pbcopy

sops ../../../platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
# Paste over placeholder; save.

git add platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
git commit -m "cloudflared: populate tunnel token"

# Re-enable Flux include for cloudflared:
sed -i '' 's|^  # - \.\./\.\./platform/kubernetes/cloudflared|  - ../../platform/kubernetes/cloudflared|' ../../../clusters/wind/kustomization.yaml
git commit -am "cluster: re-enable cloudflared (token populated)"
git push
```

#### 4. Verify cloudflared

```bash
kubectl get pods -n cloudflared       # expect 2/2 Running
kubectl logs -n cloudflared deploy/cloudflared --tail=20 | grep "Connection registered"
# expect 4 connections per replica
```

#### 5. Pre-cutover SSO test (DNS hasn't changed yet)

```bash
# Hit the tunnel directly via its cfargotunnel.com name:
open "https://$(cd infra/terraform/cloudflare && terraform output -raw tunnel_id).cfargotunnel.com/approve"
```

Should bounce to Google SSO → after auth, the approval handler responds. Confirms the tunnel + CF Access wiring works before any DNS change.

#### 6. Pre-cutover DNS verification (CF zone direct query)

Query CF's nameservers directly to confirm the records resolve there:

```bash
NS=$(cd infra/terraform/cloudflare && terraform output -json cf_nameservers | jq -r '.[0]')
for HOST in mail.etherport.net _dmarc.etherport.net wan1.wind.etherport.net; do
  echo "$HOST →"
  dig +short @$NS $HOST any | head -3
done
```

Each should return the values from `variables.tf`. If any return NXDOMAIN, fix in TF + re-apply BEFORE touching the registrar.

### Phase B — cutover (Route53 Registrar NS change — destructive)

> ⚠ Email-priority warning: this is when DNS authority changes hands. Old TTLs (up to 24h for NS records) mean some resolvers may still see Route53 for a while; CF answers for ones that re-look-up. SES sending should keep working because all email records are in CF with same values.

#### 7. Update NS at Route53 Registrar

**Where**: Route53 Registrar console (NOT the Route53 hosted zone). Path:
- AWS console → Route 53 → Registered domains → `etherport.net` → Add or edit name servers

Replace the 4 current NS values:
```
ns-1139.awsdns-14.org
ns-1606.awsdns-08.co.uk
ns-1021.awsdns-63.net
ns-1.awsdns-00.com
```

With the 2 from CF:
```
<from `terraform -chdir=infra/terraform/cloudflare output cf_nameservers`>
```

Save. Propagation typically <5min for most resolvers; up to 48h for stragglers with cached NS.

#### 8. Watch propagation

```bash
# Check global resolver view (CF's NS in answer = cut over):
watch -n 30 'dig +short NS etherport.net @8.8.8.8'

# Once you see CF nameservers, also verify a record resolves correctly:
dig +short approve.wind.etherport.net @8.8.8.8   # should be CF edge IPs
dig +short mail.etherport.net MX @8.8.8.8        # should be feedback-smtp.us-west-2.amazonses.com
```

#### 9. **CRITICAL: SES end-to-end test send**

```bash
# Send a test from one of your SES-verified accounts to yourself.
# OR trigger an alert that fires an advisor email + verify it lands (not in spam).

# Verify DKIM signature passes in the received email's "Original message" view.
# Verify SPF passes.
# Verify DMARC alignment passes.
```

If ANY of these fail, NS-flip back at registrar immediately (see Rollback below).

### Phase C — post-cutover (migrate DDNS writers)

#### 10. ddns-updater Lambda → CF API

The lambda in `infra/terraform/aws/ddns-lambda/` writes Route53 today. Route53 still ACCEPTS writes after cutover but resolvers won't see them — wan1/wan2.wind go stale on next IP change.

See `infra/terraform/aws/ddns-lambda/CF-MIGRATION.md` (scaffolded — TODO sections marked).

#### 11. route53-ddns K8s CronJob → CF API

The CronJob in `platform/kubernetes/route53-ddns/` updates `wind.etherport.net` every minute. Same story — Route53 writes silently no-op post-cutover.

See `platform/kubernetes/route53-ddns/CF-MIGRATION.md` (scaffolded — TODO sections marked).

#### 12. Switch advisor APPROVAL_BASE_URL to public CF-gated URL

```bash
# Edit platform/kubernetes/auto-remediation/deployment.yaml:
#   - name: APPROVAL_BASE_URL
#     value: "https://approve.wind.etherport.net"  (was the Tailscale URL)

git add platform/kubernetes/auto-remediation/deployment.yaml
git commit -m "advisor: switch APPROVAL_BASE_URL to public CF-gated URL"
git push
```

Next advisor email with an actionable proposal carries the CF-gated approval URL.

## Rollback

If anything breaks (especially email):

1. **NS-flip back at registrar**:
   - AWS console → Route 53 → Registered domains → `etherport.net` → Edit name servers
   - Restore the 4 original `awsdns-*` values
2. Wait ~5min for propagation. Route53 is authoritative again.
3. Email + everything else returns to pre-cutover behavior.
4. CF resources stay in place (no data loss); fix and re-cutover when ready.

Routes back to all-Route53 within minutes. No data loss because Route53 zone records were never deleted.

## DDNS Lambda migration detail

(see appendix at end of `infra/terraform/aws/ddns-lambda/CF-MIGRATION.md` once scaffolded)

## Cost summary

| Service | Cost |
|---|---|
| CF zone (Free) | $0/mo |
| CF Tunnel | $0/mo |
| CF Access (≤50 users) | $0/mo |
| **Total** | **$0/mo** |

Position to drop ALB (~$15-18/mo) once `ha.wind.etherport.net` and other ALB-fronted services are tunneled through CF.

## Audit + observability

- CF Access logs: dash → Zero Trust → Logs → Access. Every authenticated request logged with email + IP.
- cloudflared metrics: scraped by Prometheus via ServiceMonitor. Key signals:
  - `cloudflared_tunnel_active_connections` — should be 4 per replica
  - `cloudflared_tunnel_response_status_code_total` — request distribution
- Add Grafana panel for tunnel up/down (alert if active_connections < 2 for 5min).
