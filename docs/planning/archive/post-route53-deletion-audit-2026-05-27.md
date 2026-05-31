# Post-Route53-deletion audit — what's still broken

The etherport.net Route53 hosted zone was deleted earlier today as
part of the migration to Cloudflare. CF now serves DNS for the public
zone with all ~30 records correctly populated. **However**, a cluster
of writers + readers + ACME machinery was still pointing at the
deleted Route53 zone. This doc inventories them, categorizes by
urgency, and proposes a fix order.

## DDNS pipeline — fully broken

| Component | Path | What it does | State | Urgency |
|---|---|---|---|---|
| ddns-updater Lambda | `infra/terraform/aws/ddns-lambda/` | UDM router pings this Lambda with new WAN IPs; Lambda writes wan1/wan2.wind.etherport.net to Route53 | Broken (NoSuchHostedZone). Dormant — no invokers in last hour. | M → H next WAN IP change |
| cloudflare-ddns CronJob | `platform/kubernetes/cloudflare-ddns/` | K8s CronJob (every 1 min) detects active WAN by IP-source comparison, writes wind.etherport.net to Route53 | Broken; **suspended in source** (cronjob.yaml suspend=true). | M (now suspended) |
| regional-vpn workflow | `.github/workflows/terraform-regional-vpn.yml:191` | After TF creates a regional VPN, UPSERTs vpn-travel.etherport.net | Broken on next dispatch. Manual-only workflow. | L (manual trigger) |
| dns-restrict-ip Lambda | `infra/terraform/aws/dns-restrict-ip/` | Reads wan1/wan2 from Route53 every 5 min, updates SG ingress to match | Broken. Defensive check prevents SG damage but logs spam every 5 min. | M (noise; SG state safe) |

## Cert-manager / ACME

| Component | Path | State | Urgency |
|---|---|---|---|
| `letsencrypt-prod` ClusterIssuer (shortlived) | `platform/kubernetes/traefik/clusterissuer-letsencrypt.yaml` | Pointed at Route53 (deleted). Wildcard cert expires 2026-06-01; renewal Sat 2026-05-30. | **H (3-day timer)** |
| `letsencrypt-prod-classic` ClusterIssuer (RSA, UniFi) | `platform/kubernetes/traefik/clusterissuer-letsencrypt-classic.yaml` | Same. RSA cert expires 2026-08-15. | M |

Migration scaffolded in ed8a01e — both ClusterIssuers now point at a
`cloudflare-credentials` Secret in the cert-manager namespace. Secret
file is a TEMPLATE waiting for the CF token paste. See
`docs/runbooks/cert-manager-dns01-cf-migration.md`.

## CF replication completeness

The CF etherport.net zone has all the static records correctly:

- ✅ wan1.wind = 47.159.189.5 (was Route53 dynamic; now static)
- ✅ wan2.wind = 66.215.210.75 (was Route53 dynamic; now static)
- ✅ wind = 47.159.189.5 (apex active-WAN; was Route53 dynamic; now static)
- ✅ sip.wind = 47.159.189.5 (today's addition for Twilio TLS)
- ✅ ceph.wind, pve.wind = 127.0.0.1 sinkholes
- ✅ vpn-use1, vpn-usw2 (static EIPs)
- ✅ ~25 CNAMEs for CF Tunnel services, MX, TXT, DKIM, etc.

**Not replicated:**
- ❌ vpn-travel.etherport.net — created dynamically by regional-vpn
  workflow when a traveler VPN is provisioned. No record in CF.
  Workflow needs migration before next dispatch.
- ❌ Dynamic WAN IP updates — no writer pushes to CF. The static
  values above are point-in-time snapshots; if user's WAN1 IP
  changes (ISP DHCP renewal, etc.) DNS won't follow.

## Why the DDNS gap matters

Today, WAN1 IP is the same value the old writers last published
(47.159.189.5). Failover risk:

- **WAN1 IP changes:** CF still serves the OLD IP. External lookups
  (sip.wind.etherport.net → Twilio inbound, wan1.wind in cert validation,
  any external monitoring) hit the wrong address.
- **WAN2 IP changes:** same. WAN2 record points at the old IP.
- **WAN failover (active → backup):** `wind.etherport.net` apex would
  normally flip to the other WAN's IP via the cloudflare-ddns CronJob.
  With it suspended, the apex stays pinned to WAN1's IP.
- **AWS-side SG ingress:** `dns-restrict-ip` Lambda is supposed to
  re-allow SG entries for the current WAN IPs. It's currently failing
  but defensively refuses to wipe SG state, so the SG entries reflect
  whatever IPs were active last successful run (~today before deletion).
  If user's WAN IP changes, AWS-side DNS/SSH from the new IP gets
  blocked.

## Other Route53 zone-ID references (not currently invoked but worth cleaning)

| Path | What | Fix |
|---|---|---|
| `infra/terraform/aws/iam-policies/cloudflare-ddns-updater.json:21` | IAM policy with deleted hosted zone ARN | Drop the ARN or change to wildcard once writers migrate |
| `platform/kubernetes/cloudflare-ddns/README.md:55,277` | Doc examples mentioning zone ID | Update or remove after CronJob migration |
| `docs/setup/network/ubiquiti-ddns.md:135` | aws cli example | Update after writer migration |
| `docs/runbooks/regional-vpn-deployment.md:201` | aws cli example | Update with workflow |

## Other dead-zone deps

| Path | What | State |
|---|---|---|
| `docs/runbooks/aws-private-dns.md` | Runbook for the aws.etherport.net private zone | Zone deleted, marked historical |
| `platform/technitium/README.md` | Mentions the same private zone forwarder | Updated to historical |
| `infra/ansible/playbooks/technitium.yml` | Conditional forwarder for aws.etherport.net | Removed (kept us-west-2.compute.internal which is unaffected) |
| `docs/runbooks/cert-manager-wildcard.md` | "Rotate Route53 credentials" section | Rewritten for CF; old section kept as historical breadcrumb |

## Fix order (recommended)

### Phase 1 — production-critical (today)

1. **Complete cert-manager DNS-01 cutover** — paste CF token, uncomment
   resource line, commit. Force-renew to validate. 5 min.
   Without this: wildcard cert breaks 2026-06-01.

### Phase 2 — restore DDNS pipeline (1-2 hours)

2. **Migrate ddns-updater Lambda** to use CF API. UDM continues to
   call the same endpoint; Lambda writes to CF instead of Route53.
3. **Migrate cloudflare-ddns CronJob script** to use CF API. Image
   rebuild needed (drop aws-cli, use curl + CF token). Un-suspend
   after deploy.
4. **Migrate dns-restrict-ip Lambda** to use plain DNS resolution
   (no API key needed; zone-provider-agnostic). Already drafted in a
   lost local edit — re-apply.

### Phase 3 — low-urgency cleanup (when convenient)

5. **Migrate regional-vpn workflow** Route53 step to CF API.
6. **Drop the deleted zone ARN** from cloudflare-ddns-updater IAM policy.
7. **Update docs** (ubiquiti-ddns.md, regional-vpn-deployment.md,
   cloudflare-ddns README.md) for the new CF paths.
8. **Add CF DNS:Edit token** to 1P scoped per writer (vs reusing
   `cloudflare-tf-token`) so we can rotate independently.

## Effort

- Phase 1: 5 min user action (CF token paste)
- Phase 2: ~2 hours of autonomous work + 1 dispatched CI run
- Phase 3: ~1 hour of doc + IAM cleanup
