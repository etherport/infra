# AWS-infrastructure migration history (archived)

> 📦 **Historical — completed migrations.** This captures *how the AWS edge/DNS/email
> footprint got to its current shape* — chiefly the 2026-05-27 ALB → Cloudflare-Tunnel
> cutover and the Route53 → Cloudflare DNS migration. It is **not** the live reference —
> for current state see [`../aws-infrastructure.md`](../aws-infrastructure.md). Kept so the
> rationale and dated decisions behind the live design are grep-able.

All of the below is **done**. Newest first.

---

## ALB decommission → Cloudflare Tunnel + CF Access (2026-05-27)

**Then:** the `private-infra-alb` (ARN suffix `b80aa78d7562bac7`, DNS name
`private-infra-alb-687735217.us-west-2.elb.amazonaws.com`) was the external HTTPS entry
point for `*.wind.etherport.net`. The public path was **Internet → ALB → WAF
(`CreatedByALB-private-infra-alb`) → Traefik over the WireGuard tunnel**.

**Now:** the edge is the **Cloudflare Tunnel** (+ CF Access). The ALB was deleted as part
of the migration:
- 9 services (wiki, ha, plex, kopia, grafana, technitium, ollama, chat,
  `approve.etherport.net`) moved to CF Tunnel — see `infra/terraform/cloudflare/main.tf`
  for the tunnel + ingress config.
- The `*.wind.etherport.net` wildcard was removed from the CF zone.
- Public hostnames that need infra-UI access (pdu/ups/prox/switch/traefik-dashboard) became
  **Tailscale-only** — resolved internally via Technitium to the Traefik LB IP
  (`10.10.201.70`).
- The ALB-attached WAF Web ACL (`CreatedByALB-private-infra-alb`) was auto-deleted with the
  ALB.

Saves ~$25/mo + transfer. Decom runbook: [`../../runbooks/archive/alb-decom.md`](../../runbooks/archive/alb-decom.md);
CF Access enablement: [`../../runbooks/archive/cloudflare-access-enable.md`](../../runbooks/archive/cloudflare-access-enable.md).

### Deleted Terraform modules (2026-05-27)

| Module | Replaced by |
|--------|-------------|
| `load-balancing/` | ALB + WAF decom'd — CF Tunnel + CF Access |
| `route53/` | etherport.net + `aws.etherport.net` private zone deleted — CF is authoritative now |
| `cloudflare-personal/` | migrated to [sparked-diamond/personal-web](https://github.com/sparked-diamond/personal-web) `terraform/cloudflare-dns/` |

### Certificate + SES cleanup (2026-05-27)

- **ACM:** most ALB-era certs were deleted with the ALB. The three that remain
  (`*.etherport.net`, `*.wind.etherport.net`, `ha.wind.etherport.net`) are retained but no
  longer have an ALB consumer (HA moved to in-cluster TLS).
- **SES:** the personal-domain SES bits (grahamsmith.net, smithforsb.com, stopthecastle.com
  identities + DKIM + `g@grahamsmith.net` email identity) moved to the
  [personal-web](https://github.com/sparked-diamond/personal-web) repo. Only `etherport.net`
  stays here.

## ddns-updater: Route53 → Cloudflare REST API (2026-05-27)

The `ddns-updater` Lambda originally wrote to AWS Route53. After the etherport.net Route53
zone was deleted in the CF migration, it was switched to **upsert via the Cloudflare REST
API** (`https://api.cloudflare.com/client/v4`); the CF token is loaded from Secrets Manager
alongside the router shared-secret. Migration runbook:
[`../../runbooks/archive/ddns-updater-cf-migration.md`](../../runbooks/archive/ddns-updater-cf-migration.md).

## dns-restrict-ip: Route53 API → public-resolver DNS (2026-05-27)

The `dns-restrict-ip` Lambda originally read records directly from the Route53 API. With the
Route53 zone gone, it was switched to **plain DNS resolution against public resolvers**
(`1.1.1.1` then `8.8.8.8`) — zone-provider-agnostic, no API key; works against CF or whatever
else serves those names.

## Route53 health checks: ALB-era status (pre-2026-05-27)

Before the cutover, several external health checks (grafana, traefik) were disabled because of
ALB issues; after the move to CF Tunnel they remain disabled in the IaC (`grafana`, `traefik`
`enabled = false` in `external-monitoring/variables.tf`), pending re-evaluation now that
traffic flows through the tunnel (traefik is Tailscale-only with no public path).
