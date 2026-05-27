# Cloudflare full-zone management — etherport.net

## What this module owns

1. **The etherport.net zone in CF** (manually created, then imported)
2. **All 20 DNS records** mirroring current Route53 state (audited 2026-05-25)
3. **Cloudflare Tunnel** `wind-cluster` (cloudflared daemon runs in-cluster, outbound-only)
4. **Tunnel ingress config** routing `approve.etherport.net` → cluster
5. **CNAME** `approve.etherport.net → <tunnel-id>.cfargotunnel.com`
6. **CF Access Application** on the approval hostname
7. **CF Access Policy** allowing only `grahamsm@gmail.com` (Google SSO)
8. **CF Access Service Token** for the Alexa skill Lambda (file `alexa-service-token.tf`)

## What this module does NOT own

- **aws.etherport.net** PRIVATE Route53 zone — VPC-internal, not in public NS chain, no CF equivalent. Stays on Route53.
- **NS records on etherport.net at Route53 Registrar** — the destructive cutover step. Done manually in the Route53 Registrar console.
- **DDNS writers** (`ddns-updater` Lambda + `cloudflare-ddns` K8s CronJob) — they keep writing to Route53 until you migrate them to CF API per the runbook.

## Prerequisites (manual setup)

### 1. CF account + API token

- Account exists (1P item `Cloudflare`)
- API token created at https://dash.cloudflare.com/profile/api-tokens with these perms:
  - Account: Cloudflare Tunnel: Edit
  - Account: Access: Apps and Policies: Edit
  - Account: Access: Service Tokens: Edit
  - Zone: DNS: Edit
  - Zone: Zone: Edit
- Token saved to 1P as `Cloudflare API (tf)` → field `token`
- GitHub repo secrets set:
  - `CLOUDFLARE_API_TOKEN` (the token)
  - `CLOUDFLARE_ACCOUNT_ID` (hex from dashboard URL)
  - `CLOUDFLARE_ZONE_ID` (set after step 2)

### 2. Add etherport.net to CF (one-time, manual)

CF Free plan doesn't allow API-based zone creation, so do this in the dashboard:

1. dash.cloudflare.com → "+ Add a site"
2. Enter `etherport.net` → Free plan → Continue
3. Skip the "scan existing DNS" prompt (Route53 still authoritative; CF can't see records yet)
4. CF lands you on the zone overview. **Save two things from here**:
   - **The two CF nameservers** shown (e.g., `amelia.ns.cloudflare.com`, `neville.ns.cloudflare.com`) — you'll use these for the registrar NS-flip
   - **The Zone ID** (right sidebar → API section)
5. Save Zone ID + nameservers to 1P (notes on the `Cloudflare` item is fine)
6. Set GitHub repo secret `CLOUDFLARE_ZONE_ID = <hex>`

### 3. Google SSO in CF Zero Trust (one-time, ~30s)

dash.cloudflare.com → Zero Trust → Settings → Authentication → Login methods → Add Google. Click through CF's OAuth flow.

## Apply

### First-time setup — import the manually-created zone into TF state

```bash
cd infra/terraform/cloudflare
terraform init

# Import the zone (do this ONCE — TF will then manage it)
TF_VAR_cloudflare_account_id=<account-id> \
TF_VAR_cloudflare_zone_id=<zone-id> \
  terraform import cloudflare_zone.etherport <zone-id>
```

### Subsequent applies — via the workflow

```bash
gh workflow run terraform-cloudflare.yml -f action=plan   # always plan first
gh workflow run terraform-cloudflare.yml -f action=apply  # if plan looks right
```

## After apply

1. **Retrieve tunnel token**:
   ```bash
   terraform output -raw tunnel_token | pbcopy
   ```

2. **Populate the k8s SOPS secret**:
   ```bash
   sops platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
   # Paste over the REPLACE_WITH_… placeholder. Save (sops re-encrypts).
   git add platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
   git commit -m "cloudflared: populate tunnel token"
   git push
   ```

3. **Re-enable cloudflared in Flux** — uncomment the line in `clusters/wind/kustomization.yaml` we disabled to stop the crashloop:
   ```bash
   sed -i '' 's|^  # - \.\./\.\./platform/kubernetes/cloudflared|  - ../../platform/kubernetes/cloudflared|' clusters/wind/kustomization.yaml
   git commit -am "cluster: re-enable cloudflared (token populated)"
   git push
   ```

4. **Verify cloudflared in cluster**:
   ```bash
   kubectl get pods -n cloudflared           # expect 2/2 Running
   kubectl logs -n cloudflared deploy/cloudflared --tail=20  # "Connection registered" lines
   ```

5. **Pre-cutover sanity test** — hit `https://<tunnel-id>.cfargotunnel.com/approve` directly (bypasses domain DNS). Should redirect to Google SSO → after auth, lands on the approval handler (4xx with no real token is expected).

## NS cutover

See the runbook (`docs/runbooks/cloudflare-access-enable.md`) for the destructive cutover step. **Email is priority-1** — verify a test SES send works post-cutover before declaring success.

## Cost

| Service | Cost |
|---|---|
| CF zone (Free plan) | $0/mo |
| CF Tunnel | $0/mo |
| CF Access (≤50 users) | $0/mo |
| **Total** | **$0/mo** |

Long-term saves ~$15-18/mo when ALB is dropped (migrate `ha.wind.etherport.net` and any other ALB-fronted services to CF Tunnel routes).
