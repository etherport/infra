# M69 — Cloudflare Terraform provider v4 → v5 migration

**Status:** 🟡 in progress (2026-06-13). v4 baseline confirmed clean; v5 HCL
rewrite done + `terraform validate`-passing on branch `cf-provider-v5-migration`.
**Remaining: the state migration (rm+import of 51 resources) — windowed work, not yet done.**

## Progress log

- **2026-06-13 — v4 baseline (headless from mini):** `terraform plan` against
  live CF = `0 add, 1 change, 0 destroy`. The one change is a cosmetic `comment`
  drift on `cloudflare_record.a["sip.wind"]` (HCL updated for the SBC/#80 work,
  never applied). No real config drift — clean starting point.
- **2026-06-13 — v5 HCL rewrite (branch `cf-provider-v5-migration`, commit
  `3809489`):** all of `main.tf` / `alexa-service-token.tf` / `outputs.tf` /
  `providers.tf` rewritten to v5; **`terraform validate` passes against
  cloudflare v5.20.0**. Decisions baked in:
  - Dropped the v4-only provider `retries`/`min_backoff`/`max_backoff` knobs
    (v5 SDK retries internally; `parallelism=2` still gates the rate limit).
  - `cloudflare_record`→`cloudflare_dns_record`; `value`→`content`; `name` now
    full FQDN (`"${key}.${zone}"`); `allow_overwrite` dropped.
  - Tunnel + config renamed; `config{}`/`ingress_rule{}` blocks → `config = {
    ingress = [...] }` (static + map services + catch-all `concat`ed);
    `tunnel_token` now via the `..._cloudflared_token` **data source**.
  - `cloudflare_zone`: `account_id`→`account.id`, `zone`→`name`, `plan` dropped.
  - **Access policies folded inline** into each app's `policies` list (v5 drops
    the standalone `application_id`/`precedence` policy resources). HA keeps its
    ordered dual policy (service-token bypass `{service_token={token_id}}` +
    SSO `[for e in allowed_emails: {email={email=e}}]`).
- **NOT done — the dangerous part:** `validate` proves schema-correctness only,
  NOT that the live API accepts every body, and it does NOT cover the **state
  migration**. The 24 `record`→`dns_record` type renames + tunnel + folding 9
  standalone policies into apps all need `state rm` + `import {}` (with
  `-generate-config-out`) and a `plan`-to-zero-diff in a maintenance window,
  Tunnel/Access applied last and watched.
**Scope:** two repos — `infra/terraform/cloudflare/` (hard: Tunnel + Access) and
`sparked-diamond/personal-web` `terraform/cloudflare-dns/` (DNS + DNSSEC only,
owned by the personal-web thread).
**Surfaced by:** Renovate PR #48 (`update terraform cloudflare to v5`). That PR
only bumps the version *constraint* — it does NOT migrate code/state, so merging
it as-is breaks `terraform plan`. #48 is closed in favour of this plan.

## Why this is a project, not a bump

Cloudflare provider v5 is a ground-up rewrite, auto-generated from Cloudflare's
OpenAPI on the Terraform Plugin Framework. It renames resource **types** and
restructures attributes, so a re-pin alone leaves state pointing at types that
no longer exist. Every resource needs config + state reconciliation.

## Footprint — infra (`infra/terraform/cloudflare/`, pinned `~> 4.0`)

Counts below are **live-state instances** (`terraform state list`, captured
2026-06-13 headless from the mini) — `for_each`/`count` expand the resource
blocks, so the real migration surface is larger than the HCL block count. Total:
**51 resources** (47 cloudflare_* + `random_id.tunnel_secret` +
`aws_route53domains_delegation_signer_record.etherport`).

| Resource (v4) | Instances | v5 change | Risk |
|---|---|---|---|
| `cloudflare_record` | 24 | → `cloudflare_dns_record`; `value` → `content` (type rename → rm+import, not a `moved` block) | 🟡 |
| `cloudflare_tunnel` | 1 | → `cloudflare_zero_trust_tunnel_cloudflared`; secret handling changed (fed by `random_id.tunnel_secret`) | 🔴 fronts internal services |
| `cloudflare_tunnel_config` | 1 | → `cloudflare_zero_trust_tunnel_cloudflared_config` | 🔴 |
| `cloudflare_zero_trust_access_application` | 8 | policies now referenced as an ordered list of policy IDs, not inline | 🔴 gates app auth |
| `cloudflare_zero_trust_access_policy` | 9 | became standalone account-level reusable objects | 🔴 |
| `cloudflare_zero_trust_access_service_token` | 1 | minor attribute-shape change (Alexa skill) | 🟡 |
| `cloudflare_zone` | 1 | `account_id` → nested `account = { id }`; `plan` handling changed | 🟡 DNS resolution |
| `cloudflare_zone_dnssec` | 1 | attribute-shape change | 🟡 |

The 8 Access apps / 9 policies front: the AI-advisor approval URL, Home Assistant
(+ Alexa service-token policy), the wiki, and 5 tunnel-exposed services
(chat/grafana/ollama/plex/technitium). The reusable-policy rewiring (🔴) is the
bulk of the manual work.

## Headless access (resolved 2026-06-13)

The CF API token **is already in the SOPS bundle** (`homelab-ops.sops.yaml`,
key `cloudflare_api_token`) and decrypts with the on-disk age key — so the mini
runs cloudflare terraform headlessly, no `op`/VNC. (An earlier note claimed
1Password-only; that predated the bundle sync.) `terraform init` + `state list`
confirmed working from the mini against the live backend. A full `plan` needs
only `TF_VAR_cloudflare_account_id` + `_zone_id` (other vars have committed
defaults); both are derivable from the CF API with the token.

**Also:** the provider block's rate-limit tuning (`retries` / `min_backoff` /
`max_backoff`, added because v4 trips CF's 1200-req/5-min limit during parallel
refresh) uses v4 provider args. v5's Plugin Framework may rename/remove these —
re-express or drop, and keep workflow `parallelism=2`.

**Footprint — personal-web** (`terraform/cloudflare-dns/`): ~30
`cloudflare_record` + 3 `cloudflare_zone_dnssec` across 3 zones. No
Tunnel/Access — much simpler; good proving ground.

## Tooling

- TF CLI **1.14.3** is sufficient — supports `import {}` blocks +
  `terraform plan -generate-config-out`, which we use for the type-renamed
  resources (`record` → `dns_record`, `tunnel` → `..._cloudflared`).
- Cloudflare publishes **`grit` migration patterns** for v5 — run these to
  auto-rewrite most HCL, then hand-fix Access/Tunnel.
- Official v5 upgrade guide: registry docs → cloudflare/cloudflare → "Upgrading
  to v5".

## Sequence

0. **Spike (read-only, do first).** On a branch, bump to `~> 5`,
   `terraform init -upgrade`, `terraform plan`. Captures the exact
   destroy/recreate blast radius. **Requires the CF API token**, which is
   1Password-only on the mini and reachable only from an interactive VNC
   terminal (`op` does not authorize the headless agent's bash) — so run the
   spike in VNC and capture the plan. (Durable alternative: add
   `CLOUDFLARE_API_TOKEN` to the mini's SOPS-rendered env, like the AWS creds.)
1. **Rewrite HCL** via grit patterns; hand-fix the Access app↔policy wiring and
   the Tunnel resources.
2. **Reconcile state** — `terraform state mv` for same-type renames; `rm` +
   `import {}` (with `-generate-config-out`) for type changes.
3. **Plan to zero diff.** No destructive changes accepted silently.
4. **Apply in a low-traffic window**, ordered by risk: DNS records → zone /
   DNSSEC → **Tunnel + Access last and watched** (lockout / exposure risks).
5. **personal-web first** as the low-risk proving ground (DNS + DNSSEC only),
   bank the grit+import workflow, then apply lessons to infra's Access/Tunnel.
   Coordinate the provider-version bump with the personal-web thread.

## Risk notes

- **Tunnel** (`cloudflared`) fronts internal services — a destroy/recreate tears
  down the tunnel + config and breaks whatever it exposes. The tunnel secret is
  sensitive; confirm it's preserved across the import.
- **Zero Trust Access** (4 apps + 5 policies + 1 service token) gates auth in
  front of apps — mis-wiring the new reusable-policy model can lock out or
  expose apps. This is the most behaviourally different area in v5.
- **DNSSEC / zone apex** — mis-apply can break resolution for the whole zone.

## Relationships

- **task #81 / M53** — providers.tf already flags splitting the cloudflare module
  by API surface (DNS vs Access vs Tunnel) to dodge the rate limit. The v5
  rewrite is a natural moment to consider that split, and M53 (zone-scoped CF
  tokens) is independent but adjacent. Sequence CF changes; don't stack them.
- **M54** (smithforsb Single Redirect) is personal-web + blocked on M53 — not
  part of this migration.
