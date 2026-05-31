# ALB decommissioning runbook

Removes the `private-infra-alb` (us-west-2) and the `*.wind.etherport.net`
CF wildcard CNAME pointing at it. Saves ~$25/mo + data transfer.

Prerequisite: all *.wind hostnames that previously relied on the ALB
must either be (a) on CF Tunnel + Access, or (b) VPN-only with
Technitium handling internal DNS resolution.

## State as of 2026-05-27

CF Tunnel + Access (public, gated):
  chat, dns, grafana, ha, kopia, ollama, plex, technitium, wiki

VPN-only (Tailscale + WireGuard), resolved by Technitium:
  pdu1, pdu2, ups1, ups2, prox, prox-ipmi, switch1, approve (fallback),
  traefik-dashboard

The ALB still serves the wildcard path; no traffic from CF-migrated
hostnames reaches it (CF explicit records win over the wildcard).
Operator UIs still resolve to the ALB externally — removing the
wildcard takes that public path offline.

## Pre-flight checks (do these on-site or via VPN)

1. **Confirm VPN resolves every operator hostname to 10.10.201.70:**

   ```bash
   # While connected to Tailscale or WireGuard:
   for h in pdu1 pdu2 ups1 ups2 prox prox-ipmi switch1 approve; do
     printf '%-20s ' "$h.wind.etherport.net"
     dig +short "$h.wind.etherport.net" @10.10.201.5  # Technitium
   done
   ```

   Expected: all return `10.10.201.70` (Traefik LB).

2. **Confirm Traefik IngressRoute Host matches for each:**

   ```bash
   kubectl get ingressroute -A -o json | \
     jq -r '.items[].spec.routes[].match' | \
     grep wind.etherport.net | sort -u
   ```

   Compare against the Technitium zone — every Host in the IngressRoutes
   must have a record in `platform/kubernetes/technitium/zones/wind.etherport.net.yaml`.

3. **Test a sample operator UI via VPN:**

   ```bash
   curl -sI https://pdu1.wind.etherport.net/  # should succeed via VPN
   ```

4. **Confirm CF-Tunnel-fronted hostnames still work** (they should be
   unaffected since they have explicit CF records):

   ```bash
   curl -sI https://wiki.wind.etherport.net/  # 302 → CF Access
   ```

## Execution

### Step 1 — drop the wildcard CNAME

```bash
cd infra/terraform/cloudflare
CF_TOKEN=$(op item get cloudflare-tf-token --fields credential --reveal)
export TF_VAR_cloudflare_account_id=5576c21a0ddcaf20219210514c265f12
export TF_VAR_cloudflare_zone_id=c45213cbf36fc634b6b75ae9abd49c59
export CLOUDFLARE_API_TOKEN="$CF_TOKEN"

terraform plan -out=/tmp/wildcard-decom.tfplan
# Should show: -1 destroy (cloudflare_record.cname["*.wind"]), 0 changes
terraform apply /tmp/wildcard-decom.tfplan
```

After this:
- External DNS for `<anything>.wind.etherport.net` (other than explicit
  CF records) returns NXDOMAIN.
- VPN clients still resolve via Technitium → Traefik LB → operator UI.

### Step 2 — destroy the ALB

```bash
cd infra/terraform/aws/load-balancing
terraform plan -destroy -out=/tmp/alb-destroy.tfplan
# Should show: all aws_lb*, aws_lb_listener*, aws_lb_target_group* destroyed
terraform apply /tmp/alb-destroy.tfplan
```

The ACM certificates themselves live in `infra/terraform/aws/acm/`
and are NOT destroyed — they remain available for any future use.

> **Historical note (2026-05-27):** the `load-balancing/` module was
> deleted from the repo after the destroy completed (commit `7a369f4`).
> Rollback per the section below requires `git revert` to recreate the
> module dir before re-applying.

### Step 3 — verify

1. **Public resolution returns NXDOMAIN for operator UIs:**

   ```bash
   dig +short pdu1.wind.etherport.net @1.1.1.1
   # expect empty / NXDOMAIN
   ```

2. **VPN still works:** repeat the pre-flight checks.

3. **CF-Tunnel apps unaffected:** `curl -sI https://wiki.wind.etherport.net/`
   still returns 302.

4. **AWS console:** no ALB in us-west-2; cost dashboard shows ~$25/mo
   savings starting next billing period.

## Rollback (if something goes wrong)

The module dir was deleted post-decom; reinstating it is a two-step
revert:

```bash
# Restore the module + TF state intent
git revert <commit that deleted load-balancing/>   # e.g., 7a369f4
git revert <ALB destroy commit>
cd infra/terraform/aws/load-balancing
terraform init
terraform apply  # recreates the ALB
```

The `*.wind.etherport.net` ACM cert was kept (used by other
consumers); listener attachments re-bind automatically on apply.

Then revert the CF wildcard removal commit + apply.

Rollback window: minutes after destroy, the ALB is gone. ACM still
holds the certs. DNS reverts take 5-10 min to propagate.

## Cost impact

| Item | Before | After |
|---|---|---|
| ALB hourly | ~$0.0225/hr = $16/mo | $0 |
| ALB LCU usage | varies, ~$2-5/mo at low traffic | $0 |
| Data transfer through ALB | varies | $0 |
| ACM certs | $0 (free) | $0 (no change) |
| Total | **~$20-30/mo** | **$0** |
