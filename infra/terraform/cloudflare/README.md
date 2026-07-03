# Cloudflare full-zone management — etherport.net

Manages the **`etherport.net` zone in Cloudflare** (CF is authoritative for the domain), its
**Cloudflare Tunnel** + ingress, and the **CF Access** apps in front of tunnel-exposed services —
plus a small **cross-zone** footprint (SPF hardening on other CF zones, see item 9).
Ships via the `terraform-cloudflare.yml` GitHub Actions workflow. CF Free plan, **$0/mo**.

> CF provider **v5** (`cloudflare/cloudflare ~> 5.0`). Access policies are **inline** on each app;
> the tunnel token comes from a data source. Run plan/apply at **`-parallelism=2`** (the workflow
> does) to stay under CF's API rate limit. On the Linux **devbox**, any `pbcopy` / BSD `sed -i ''`
> snippets below are macOS-only — use `xclip` / GNU `sed -i` instead.

## What this module owns

1. **The `etherport.net` zone in CF** — imported (CF Free can't create a zone via API, so the zone
   is added once in the dashboard, then `terraform import`ed). `prevent_destroy` guards it.
2. **All `etherport.net` DNS records** — A / CNAME / MX / TXT, each `for_each` over a map in
   `variables.tf` (adding a record is a one-line change). Includes SES email records (DKIM/SPF/
   DMARC/MX — **email-critical**), ACME DNS-01 validation records for cert-manager, AWS VPN-endpoint
   A records, internal-only sinkholes (`ceph.wind`/`pve.wind` → 127.0.0.1), and the **DDNS-managed**
   records (`wan1.wind`/`wan2.wind`/`wind`/`sip.wind` — see "does NOT own" for who writes them).
3. **DNSSEC** — `cloudflare_zone_dnssec` (CF signs the zone) + the registrar-side DS record published
   at the AWS Route53 Domains registrar via `aws_route53domains_delegation_signer_record`
   (`dnssec-registrar.tf` — this is the only thing the bundled AWS provider does).
4. **Cloudflare Tunnel `wind-cluster`** — the `cloudflared` daemon runs in-cluster (outbound-only,
   `platform/kubernetes/cloudflared/`); tunnel config source is `cloudflare` (ingress managed here
   via the API, not a local cloudflared file).
5. **Tunnel ingress config** — routes the tunnel-exposed hostnames to in-cluster Services:
   `approve.etherport.net`, `wiki.wind.etherport.net`, `ha.wind.etherport.net`,
   `cue.etherport.net`, plus everything in the `cf_tunnel_services` map, plus the required
   `http_status:404` catch-all.
6. **DNS CNAMEs → tunnel** (`<tunnel-id>.cfargotunnel.com`, proxied) for each tunnel hostname.
7. **CF Access applications + inline policies** (Google SSO unless noted):
   - **`approve`** — AI Advisor approval URL; allows `allowed_emails`.
   - **`wiki`** — Wiki.js; allows `allowed_emails`.
   - **`ha`** — Home Assistant, **dual-policy**: a non-identity **service-token** policy for the
     Alexa skill Lambda (it can't follow SSO redirects), then a browser-SSO policy.
   - **`cue` (per-path, `cue-access.tf`)** — CF matches most-specific path first:
     `/health` → **service token** (`cue-health-probe`, used by the in-cluster blackbox probe with
     CF-Access headers from a SOPS Secret; replaced the old bypass+everyone policy 2026-07-03 after a
     CF "Overprovisioned Access Policies" insight), `/ingest/healthkit` → **service token** (Apple
     Health Auto Export), everything else → **allow `cue_tester_emails`** (SSO).
   - **`cf_tunnel_services`** map — one CNAME + Access app (allow `allowed_emails`) per entry.
     Current entries: `technitium.wind`, `grafana.wind`, `plex.wind`, `ollama.wind`, `chat.wind`,
     `backup-approve.wind`.
8. **CF Access Service Tokens** — `alexa_skill` (Alexa Lambda → HA, `alexa-service-token.tf`),
   `cue_healthkit` (Apple Health → Cue) and `cue_health_probe` (in-cluster blackbox → `/health`),
   both in `cue-access.tf`. Client ID/secret are TF outputs.
9. **Cross-zone security-insight remediations** (`insights-cross-zone.tf`, 2026-07-03) — hard-fail
   SPF (`v=spf1 -all`) TXT records on the receive-only `mail.grahamsmith.net` +
   `mail.stopthecastle.com` names (via `cloudflare_zones` data lookups — the CI token's DNS scope is
   all-zones), and **Bot Fight Mode** for `etherport.net` (`cloudflare_bot_management` — apply
   pending the "Zone: Bot Management: Edit" token scope; the three personal-web zones' BFM is
   managed by the personal-web repo instead).

## What this module does NOT own

- **`aws.etherport.net`** — the PRIVATE Route53 zone (VPC-internal resolution, not in the public NS
  chain, no CF equivalent). Stays on Route53.
- **NS records for `etherport.net` at the Route53 Registrar** — set manually in the Registrar
  console; CF is authoritative (see Migration history).
- **DDNS writers** — the `ddns-updater` Lambda (`infra/terraform/aws/ddns-lambda/`, writes
  `wan1.wind`/`wan2.wind`) and the `cloudflare-ddns` K8s CronJob
  (`platform/kubernetes/cloudflare-ddns/`, writes the active-WAN `wind` + `sip.wind`). They write the
  record *values* via the CF API every minute; this module only declares the records (placeholders +
  `lifecycle.ignore_changes`).

## Prerequisites (manual setup)

### CF account + API token

- Account exists (1P item `Cloudflare`).
- API token created at https://dash.cloudflare.com/profile/api-tokens with these scopes:
  - Account: Cloudflare Tunnel: Edit
  - Account: Access: Apps and Policies: Edit
  - Account: Access: Service Tokens: Edit
  - Zone: DNS: Edit — **all zones** (the cross-zone SPF records in `insights-cross-zone.tf`
    rely on this; it is not etherport-only)
  - Zone: Zone: Edit
  - Zone: Bot Management: Edit (needed by `cloudflare_bot_management.etherport`; being added —
    the BFM apply is pending this scope)
  - (No "Account: Zone: Edit" — the zone is dashboard-created, not API-created.)
- Token saved to 1P as `Cloudflare API (tf)` → field `token`.
- GitHub repo secrets set:
  - `CLOUDFLARE_API_TOKEN` (the token)
  - `CLOUDFLARE_ACCOUNT_ID` (hex from the dashboard URL)
  - `CLOUDFLARE_ZONE_ID` (hex from the CF zone overview → API section)

### Google SSO in CF Zero Trust (one-time, ~30s)

dash.cloudflare.com → Zero Trust → Settings → Authentication → Login methods → Add Google. Click
through CF's OAuth flow. The Google IdP UUID is the `google_idp_id` variable.

## Apply

Subsequent changes ship via the workflow — **always plan first**:

```bash
gh workflow run terraform-cloudflare.yml -f action=plan    # review the plan
gh workflow run terraform-cloudflare.yml -f action=apply   # if the plan looks right
```

> First-time-only: the zone must be imported into TF state once
> (`terraform import cloudflare_zone.etherport <zone-id>`) — see Migration history.

### Adding a tunnel-exposed service

1. Add an entry to `cf_tunnel_services` in `variables.tf` (key = subdomain-relative-to-zone, e.g.
   `grafana.wind`; value = `cluster_service_url` + `access_name`). This generates the CNAME + tunnel
   ingress rule + Access app + policy together.
2. `gh workflow run terraform-cloudflare.yml -f action=plan` then `apply`.
3. (Optional) Add a Technitium A record for split-horizon LAN access.
4. (Optional) Tighten the origin's own auth — e.g. for Plex, add the cloudflared pod CIDR
   (`10.42.0.0/16`) to its "LAN Networks" so it treats tunnel traffic as local and skips its login.

For a service that needs per-path Access behaviour (bypass / service token / SSO on different paths),
follow the `cue-access.tf` pattern instead of the map (CF matches the most-specific app path first).

## After apply (tunnel token → cluster)

Only needed if the tunnel was (re)created or its token rotated; the in-cluster cloudflared is
already running normally.

1. **Retrieve the tunnel token** (`pbcopy` → `xclip -selection clipboard` on the devbox):
   ```bash
   terraform output -raw tunnel_token | pbcopy
   ```
2. **Populate the k8s SOPS secret** and commit:
   ```bash
   sops platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml   # paste over the placeholder
   git add platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
   git commit -m "cloudflared: populate tunnel token" && git push
   ```
3. **Verify cloudflared in-cluster**:
   ```bash
   kubectl get pods -n cloudflared                                  # expect 2/2 Running
   kubectl logs -n cloudflared deploy/cloudflared --tail=20         # "Connection registered" lines
   ```

## Cost

| Service | Cost |
|---|---|
| CF zone (Free plan) | $0/mo |
| CF Tunnel | $0/mo |
| CF Access (≤50 users) | $0/mo |
| **Total** | **$0/mo** |

## Migration history

The Route53 → Cloudflare cutover, the ALB → CF Tunnel moves, the v4 → v5 provider migration, and the
DNSSEC chain setup are archived in
[`archive/cloudflare-migration-history.md`](archive/cloudflare-migration-history.md).
