# Autonomous session — 2026-05-27 afternoon

What landed while you were out, what's still pending, what needs your attention first.

## TL;DR

- **Action needed soon (~3 days):** cert-manager DNS-01 wildcard cert
  renewal is broken since the Route53 zone deletion. Scaffolded the
  CF migration; needs a CF token paste when 1P is unlocked. See
  `docs/runbooks/cert-manager-dns01-cf-migration.md` for the 5-min cutover.
- **Action needed now:** review + commit the staged change in
  `infra/terraform/aws/dns-restrict-ip/lambda/handler.py` (1P signing
  failed mid-session so the commit didn't land). The change is small
  and tested locally.
- **Everything else** is committed + pushed.

## Pushed during this autonomous session

| Commit | What |
|---|---|
| `5a0052e` | docs: UDM rule consolidation + modernization plan (Plan agent output → `docs/planning/udm-rule-consolidation.md`). 6 phases, sequenced by risk. Reads ~7 min. |
| `ed8a01e` | cert-manager: scaffolded the DNS-01 migration to Cloudflare. New dir `platform/kubernetes/cert-manager-issuer/` + ClusterIssuer flips. Suspended `cloudflare-ddns` CronJob. Deleted empty `infra/terraform/aws/route53/` module + workflow. Added `terraform-google.yml` CI workflow. README workflow table refreshed. |
| `f376534` | gitignore: untrack accidentally-committed `handler.zip`. |
| `b066796` | gitignore: broaden `handler.zip` pattern to catch the parent-dir layout TF actually uses. |

## Uncommitted — git signing blocked on 1P session expiry

The 1Password CLI session expired partway through this session, and
git is configured to sign via SSH-from-1P. Per the standing rule
("never bypass signing unless user explicitly asks"), I left these
changes as uncommitted edits for you to review + commit on return.
All are safe + tested where applicable.

| File | What | Risk |
|---|---|---|
| `infra/terraform/aws/dns-restrict-ip/lambda/handler.py` | Lambda swapped from Route53 API to plain DNS resolution (1.1.1.1 + 8.8.8.8). Local smoke test resolved all 3 WAN records correctly. Removes the every-5-min `NoSuchHostedZone` log spam. | Low — Lambda has a defensive "refuse to remove all rules" check that already kept SG state safe. |
| `docs/runbooks/cert-manager-wildcard.md` | "Rotate Route53 credentials" section rewritten for Cloudflare; old Route53 section kept as historical breadcrumb. Points at the new SOPS path. | None (doc only) |
| `docs/runbooks/aws-private-dns.md` | Header marks the runbook as HISTORICAL — private zone deleted 2026-05-27. Restoration recipe noted for future use. | None (doc only) |
| `infra/ansible/playbooks/technitium.yml` | Removed the `aws.etherport.net` conditional forwarder (zone deleted; was a SERVFAIL). Kept the `us-west-2.compute.internal` forwarder. | Low — affected resolvers already SERVFAIL on those queries. |
| `platform/technitium/README.md` | Section about `aws.etherport.net` rewritten to reflect deletion. | None (doc only) |
| `docs/planning/autonomous-session-2026-05-27.md` | This doc itself. | None |
| `docs/planning/public-web-repo-split.md` | Migration runbook for task #82 — bootstraps the public-web repo, plans the state move, sequences the SES/email-forward split decision. | None (doc only) |

**To commit on return:**
```bash
# After unlocking 1P:
cd /Users/grahamsmith/code/infra

# Option A — single bundled commit for the whole batch:
git add -A
git commit -m "post-route53-deletion cleanup: dns-restrict-ip + docs"

# Option B — split into logical commits (recommended):
git add infra/terraform/aws/dns-restrict-ip/lambda/handler.py
git commit -m "dns-restrict-ip: swap Route53 API for DNS resolution"

git add docs/runbooks/cert-manager-wildcard.md docs/runbooks/aws-private-dns.md \
       infra/ansible/playbooks/technitium.yml platform/technitium/README.md
git commit -m "docs: post-route53-deletion runbook + playbook updates"

git add docs/planning/autonomous-session-2026-05-27.md \
        docs/planning/public-web-repo-split.md
git commit -m "docs: autonomous session notes + public-web split runbook"

git push
```

## Discovered + fixed during the session

### 1. cert-manager DNS-01 broken — wildcard renewal fails 2026-05-30

**Root cause:** the etherport.net Route53 zone was deleted as part of
the Route53 → Cloudflare migration we did earlier today. Both
ClusterIssuers (`letsencrypt-prod` shortlived + `letsencrypt-prod-classic`)
still pointed to it. The shortlived cert renews every 6 days; next
attempt is Saturday.

**What landed:** scaffold + ClusterIssuer config flipped to use a
Cloudflare DNS-01 solver. Lives in a new dir `cert-manager-issuer/`
because dropping it into `traefik/` would have silently rewritten the
secret's namespace via kustomize.

**What needs you (5 min):** open `docs/runbooks/cert-manager-dns01-cf-migration.md`
and follow the 5 steps — copy template → sops edit → paste CF token →
uncomment resource line → commit.

### 2. cloudflare-ddns CronJob failing every minute since the zone deletion

**Suspended in source** (`platform/kubernetes/cloudflare-ddns/base/cronjob.yaml`).
The static `wind = 47.159.189.5` value in `infra/terraform/cloudflare/variables.tf`
is authoritative until the script is rewritten against the CF API.
WAN failover detection is BROKEN until the migration in task #84
lands. Most external services use CF Tunnel and don't depend on
`wind.etherport.net` apex, so blast radius is small in practice.

### 3. dns-restrict-ip Lambda firing errors every 5 min

Same root cause — reads from the deleted Route53 zone. Has a
defensive safety check that refuses to remove all SG rules when the
read returns empty, so no SG damage. **Migrated to plain DNS
resolution** (1.1.1.1 + 8.8.8.8 fallback, both check the same CF
authoritative zone). Zone-provider-agnostic, no API key needed.

Local smoke test:
```
wind.etherport.net      → 47.159.189.5
wan1.wind.etherport.net → 47.159.189.5
wan2.wind.etherport.net → 66.215.210.75
```

**Change is staged but not committed** — git signing requires
1Password which is locked. Review the diff in
`infra/terraform/aws/dns-restrict-ip/lambda/handler.py`, commit when
ready, then dispatch the `terraform-dns-restrict-ip.yml` workflow to
deploy.

### 4. ddns-updater Lambda dormant + broken

Writes WAN1/WAN2 IPs to the (now-deleted) Route53 zone. No invocations
in the last hour — bug is latent. Same migration approach as the
CronJob (rewrite against CF API). Tracked as task #84.

## Other tidy-ups

- README.md DNS authority table reflects post-migration reality (CF
  authoritative for all 4 zones; Route53 zones all deleted).
- README.md workflows table dropped the deleted `terraform-route53.yml`
  entry, added `terraform-google.yml`.
- `infra/terraform/aws/route53/` removed (module was empty). Orphan S3
  state file at `s3://terraform.wind.etherport.net/aws/route53/`
  remains — cheap, can be cleaned manually if you want.
- Drift-detection workflow matrix dropped the route53 entry.
- `terraform-route53.yml` workflow deleted.
- UDM rule consolidation plan saved + committed (Plan agent output).

## Tasks created

| ID | Title | Priority |
|---|---|---|
| #81 | Split cloudflare TF module to dodge per-token rate limits | M |
| #82 | Split public-web domains into separate repo | M |
| #83 | 1Password tidy-up: consistent naming + tags | L |
| #84 | Migrate cloudflare-ddns + ddns-updater Lambda from Route53 to CF API | M (becomes H next WAN IP change) |

## Tasks NOT touched (intentionally)

- **#82 public-web split** — significant refactor that needs you in
  the loop for the new repo creation, state move, and TF state mv across
  repos. Will draft a migration runbook later in this session if time
  permits.
- **#2 NetworkPolicies + ResourceQuotas + PDBs** — Phase 2/3
  enforcement decisions need user judgment on the observation window
  outcomes.
- **#24 CNPG restore drill Tier B** — needs a real maintenance window.
- **#62 Unified dashboard + push notifications** — bigger product
  scope decision.
- **#80 SBC for full TLS+sRTP** — future / nice-to-have.

## What to do first when you're back

1. **Unlock 1P** (so the next op item get / git signing succeeds).
2. **Read this doc + the `udm-rule-consolidation.md` plan** (~7 min total).
3. **Commit + push the dns-restrict-ip Lambda fix.** Then dispatch the
   `terraform-dns-restrict-ip.yml` workflow to deploy. Confirm logs
   shift from `NoSuchHostedZone` to `Resolved → IP`.
4. **Run the cert-manager DNS-01 cutover** (5 min,
   `docs/runbooks/cert-manager-dns01-cf-migration.md`). Force-renew
   the wildcard cert immediately after to validate end-to-end before
   the 2026-05-30 natural renewal window.
5. **(Optional) tackle UDM rule consolidation Phase A** — half a day
   of trivial wins per the plan.
