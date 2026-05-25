# Cloudflare Tunnel + Access for wind.etherport.net

## What this module creates

1. **Cloudflare zone** `wind.etherport.net` (subdomain — etherport.net stays on Route53)
2. **DNS records** mirroring current `wind.etherport.net` Route53 records (so service hosts keep working after delegation)
3. **Cloudflare Tunnel** `wind-cluster` (cloudflared daemon runs in-cluster, no inbound ports)
4. **Tunnel ingress config** routing `approve.wind.etherport.net` → `http://remediation-webhook.auto-remediation.svc.cluster.local:8080`
5. **DNS CNAME** `approve.wind.etherport.net → <tunnel-id>.cfargotunnel.com` (proxied via CF)
6. **CF Access Application** on the approval hostname
7. **CF Access Policy** allowing only `grahamsm@gmail.com` (via Google SSO)

## Prerequisites — do these manually in the CF dashboard first

### Cloudflare account

- Account exists (1P item: "Cloudflare", `grahamsm@gmail.com`)
- Find your **Account ID**: dash.cloudflare.com → right sidebar → "Account ID"

### API token

Create at https://dash.cloudflare.com/profile/api-tokens → "Create Custom Token":

| Permission | Scope |
|---|---|
| Account / Cloudflare Tunnel / Edit | All accounts |
| Account / Access: Apps and Policies / Edit | All accounts |
| Account / Zone / Edit | All accounts |
| Zone / DNS / Edit | All zones |
| Zone / Zone / Read | All zones |

Save to 1Password:
- Item name: `Cloudflare API (tf)`
- Field: `token` (Concealed type)

Then in this repo's GitHub repo secrets, add:
- `CLOUDFLARE_API_TOKEN` (paste the token value)

### Google SSO IdP in Cloudflare Zero Trust

Dashboard: dash.cloudflare.com → Zero Trust → Settings → Authentication → Login methods → Add a new login method → Google.

Click through CF's Google OAuth flow — no separate Google Cloud project needed; CF provides a hosted relay.

## Apply

```bash
# Sanity-check the module first
cd infra/terraform/cloudflare
terraform init
terraform plan \
  -var "cloudflare_account_id=<YOUR_ACCOUNT_ID>"

# If plan looks right (no NS delegation yet, just CF-side resources)
terraform apply \
  -var "cloudflare_account_id=<YOUR_ACCOUNT_ID>"
```

(Or use the GitHub workflow `terraform-cloudflare.yml` after the secrets are wired.)

## After apply

1. **Retrieve tunnel token**:
   ```bash
   terraform output -raw tunnel_token | pbcopy
   ```

2. **Populate the k8s SOPS secret**:
   ```bash
   sops platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
   # Paste the token in `token` field; save.
   git add platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
   git commit -m "cloudflared: populate tunnel token"
   git push
   ```

3. **Verify cloudflared in cluster comes up**:
   ```bash
   kubectl get pods -n cloudflared
   kubectl logs -n cloudflared deploy/cloudflared --tail=30
   ```
   Should show `Connection registered` × 2 (one per HA replica).

4. **Verify the tunnel route + DNS pre-cutover**:
   ```bash
   dig +short approve.wind.etherport.net @1.1.1.1
   # ↑ Still answers from Route53 (current value) because NS delegation
   #   hasn't happened yet. After step 5, this answers from CF.
   ```

5. **Cut over wind.etherport.net to Cloudflare DNS** (the destructive step):
   - Fill in the actual current Route53 A-record values into `variables.tf` for the `existing_wind_records` map (the REPLACE_WITH_CURRENT placeholders).
     ```bash
     # Get current values
     for NAME in wind '\\052.wind' wan1.wind wan2.wind ceph.wind ha.wind pve.wind; do
       VAL=$(aws --profile homelab route53 list-resource-record-sets \
         --hosted-zone-id $(aws --profile homelab route53 list-hosted-zones \
           --query 'HostedZones[?Name==`etherport.net.`].Id' --output text | sed 's|/hostedzone/||') \
         --query "ResourceRecordSets[?Name=='${NAME}.etherport.net.' && Type=='A'].ResourceRecords[0].Value" \
         --output text)
       echo "$NAME → $VAL"
     done
     ```
   - Re-apply: `terraform apply` (updates CF records with real values).
   - Add NS records in Route53 etherport.net pointing wind.etherport.net to:
     ```bash
     terraform output cf_nameservers
     ```
   - Edit `infra/terraform/aws/route53/records-etherport.tf` to add:
     ```hcl
     resource "aws_route53_record" "wind_ns_delegation" {
       zone_id = aws_route53_zone.etherport.zone_id
       name    = "wind.etherport.net"
       type    = "NS"
       ttl     = 300
       records = ["<cf-ns-1>", "<cf-ns-2>"]
     }
     ```
   - Apply Route53.
   - Wait for propagation (~5min, max 24h). `dig +short approve.wind.etherport.net @1.1.1.1` now answers from CF.

6. **Switch the advisor to use the public URL**:
   - Edit `platform/kubernetes/auto-remediation/deployment.yaml`:
     ```yaml
     - name: APPROVAL_BASE_URL
       value: "https://approve.wind.etherport.net"
     ```
   - Commit + push. Flux applies. Next advisor email uses the CF-gated public URL.

## Cost

- Cloudflare zone: free
- Cloudflare Tunnel: free
- Cloudflare Access (Free tier): up to 50 users — way more than needed
- Total: **$0/mo** (vs. ~$15-18/mo for the ALB this replaces if you ever migrate other services off too)

## Rollback

If anything breaks the approval flow:
1. Switch APPROVAL_BASE_URL back to the Tailscale URL (`remediation-approve.<tailnet>.ts.net`)
2. Optionally remove the NS delegation in Route53 to restore Route53 as authoritative for wind.etherport.net (CF resources can stay — they just stop receiving traffic)

## What's next (future)

- Migrate other public-with-auth services (Grafana, Home Assistant, anything currently behind ALB+Cognito) to add their own CF Access app + tunnel route. Same pattern, ~10 lines of TF per service.
- Once nothing's behind ALB, terraform destroy the ALB → saves ~$15-18/mo.
