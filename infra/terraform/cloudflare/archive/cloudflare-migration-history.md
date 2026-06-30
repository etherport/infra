# Cloudflare migration history (archived)

> 📦 **Historical — completed migrations.** This captures *how the etherport.net DNS / CF
> Tunnel / CF Access setup got to its current shape* (the Route53 → Cloudflare cutover and the
> ALB → CF Tunnel moves). It is **not** the live reference — for current state see
> [`../README.md`](../README.md). Kept so the rationale and dated decisions behind the live
> design are grep-able.

All of the below is **done**. Newest first.

---

## Route53 → Cloudflare cutover (COMPLETE 2026-05-27)

`etherport.net` is now **authoritative at Cloudflare** — Route53 is no longer in the public NS
chain for the zone. The migration ran in this order:

1. **Mirror Route53 → CF (no cutover yet).** TF created the whole `etherport.net` zone's records
   in CF mirroring the then-current Route53 state, while **Route53 stayed authoritative**. The
   record audit was done **2026-05-25**: 22 records, dropped the 2 stale apex `wan1`/`wan2`
   records (not in the lambda allowlist, not in TF, not in any active path), preserved the other
   20 exactly. Email-critical (SES DKIM/SPF/DMARC/MX) records were ordered first in each map for
   visibility and end-to-end tested before declaring success.
2. **Add `etherport.net` to CF (one-time, manual).** CF Free plan doesn't allow API-based zone
   creation (or partial/subdomain-only hosting), so the zone was added via the dashboard
   (`+ Add a site` → `etherport.net` → Free), skipping the "scan existing DNS" prompt (Route53
   was still authoritative, so CF couldn't see the records yet). The two CF nameservers and the
   Zone ID were captured from the zone overview; Zone ID went to GitHub secret
   `CLOUDFLARE_ZONE_ID`.
3. **Import the zone into TF state** — `terraform import cloudflare_zone.etherport <zone-id>`
   (once); thereafter TF manages it. `prevent_destroy` guards against an accidental destroy that
   would delete all records + break DNS authority.
4. **NS cutover at the registrar (destructive, reversible).** `etherport.net`'s NS records were
   flipped at the **Route53 Registrar console** (the registrar — NOT the Route53 hosted zone) to
   the two CF nameservers (output `cf_nameservers`). After delegation propagated CF answered all
   `etherport.net` queries. **Email was priority-1**: a test SES send was verified post-cutover
   before declaring success. Full destructive-step runbook:
   [`docs/runbooks/archive/cloudflare-access-enable.md`](../../../../docs/runbooks/archive/cloudflare-access-enable.md).
5. **DDNS writers migrated to the CF API.** Both writers — the `ddns-updater` Lambda
   (`infra/terraform/aws/ddns-lambda/`, writes `wan1.wind`/`wan2.wind`) and the `cloudflare-ddns`
   K8s CronJob (`platform/kubernetes/cloudflare-ddns/`, writes the active-WAN `wind` record) — were
   rewritten to use the **Cloudflare DNS API** instead of Route53. (`sip.wind` was added to the
   CronJob's `record_names` on **2026-06-07** so the Twilio→Asterisk SBC origination record tracks
   the active WAN too.) Their A-record values in `variables.tf` are placeholders overwritten on
   first run; `lifecycle.ignore_changes` keeps TF from fighting them.
6. **Route53 zone deleted 2026-05-27.** Once CF was authoritative and verified, the public
   `etherport.net` Route53 hosted zone was deleted. (The **private** `aws.etherport.net` Route53
   zone is unrelated — VPC-internal, never in the public NS chain — and stays on Route53.)

After this, DNS is **CF-only**; nothing in the system writes to Route53 for public
`etherport.net` resolution.

## ALB → CF Tunnel migrations (2026-05-26 → 2026-06-23)

Public ingress moved off the AWS ALB / `*.wind.etherport.net` wildcard onto CF Tunnel routes,
service by service:

- **wiki-js** (`wiki.wind.etherport.net`) — first ALB → CF Tunnel migration, **2026-05-26**.
- **Wildcard `*.wind.etherport.net` CNAME dropped 2026-05-27.** Replaced by VPN-only access
  (Tailscale + WireGuard) for the operator UIs that were its last legitimate users
  (`pdu1/2`, `ups1/2`, `prox-ipmi`, `prox`, `switch1`, `traefik-dashboard`). Those hostnames now
  resolve **internally via Technitium** to the Traefik LB IP `10.10.201.70`
  (`platform/kubernetes/technitium/zones/wind.etherport.net.yaml`); external DNS returns NXDOMAIN.
  Same change: missing Technitium A records added (`switch1`, `approve`), wildcard dropped from
  the CF zone, **ALB destroyed + the `load-balancing/` TF module deleted** (~$25/mo + transfer
  savings).
- **Home Assistant** (`ha.wind.etherport.net`) — moved onto the tunnel, fronted by a dual-policy
  CF Access app (Alexa Lambda service token + browser SSO), replacing the ALB alias.
- **Cue API** (`cue.etherport.net`) — **2026-06-23**, the tunnel ingress was widened to serve the
  **whole** app (the old `/health|/telegram` path-limit was removed when Telegram was dropped); CF
  Access now gates per-path via three composed apps (`cue-access.tf`).

## CF provider v4 → v5 (M69, 2026-06-13)

The module migrated from `cloudflare/cloudflare ~> 4.0` to `~> 5.0`. Structural changes: `record`
→ `dns_record`, tunnel/config resource renames, zone `account` nesting, **inline** Access policies
(the standalone `cloudflare_zero_trust_access_policy` + `application_id` model is gone), the tunnel
token moved to a dedicated data source, and `connect_timeout` became a number-of-seconds. Two
v5-specific gotchas now codified as `lifecycle` blocks:
- `cloudflare_zone_dnssec` — `status` became a settable attribute; omitting it plans `status -> null`
  (disabling DNSSEC) and pinning `"active"` fights CF's server-side pending state. Activation is a CF
  lifecycle, not TF-driven → `ignore_changes = [status]`.
- `cloudflare_zero_trust_tunnel_cloudflared` — `tunnel_secret` is write-only (the API never returns
  it), so after import a plan wants to re-set it from `random_id`, re-issuing the token and dropping
  the live cloudflared connection → `ignore_changes = [tunnel_secret]`.

The full per-resource rename map lives in `docs/planning/cloudflare-provider-v5-migration.md`; the
helper `migrate-v5.sh` automated the state moves.

## DNSSEC chain established (registrar DS publication)

CF generates the KSK and signs the zone (`cloudflare_zone_dnssec.etherport`); the corresponding DS
record is published at the **AWS Route53 Domains registrar** (parent zone) via
`aws_route53domains_delegation_signer_record.etherport` (`dnssec-registrar.tf`) so resolvers can
validate the chain. The DS is live + correct at the registrar (algo 13, keyTag 2371); the resource
carries `ignore_changes = [signing_attributes]` because on import the AWS API doesn't return them in
a form that round-trips against the CF-sourced values (would otherwise destroy+recreate the DS on
every plan and briefly break the chain). Re-import if the CF KSK is ever rotated.
