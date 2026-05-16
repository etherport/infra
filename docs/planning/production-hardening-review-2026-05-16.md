# Production-readiness review — 2026-05-16

Hardening review after this week's cluster rebuild reached steady state.
Filter: production best practices at this scale (~$50/mo AWS, ~10
public-facing services, single operator). Enterprise patterns are called
out and skipped where they're not worth it.

Refs: `long-term-stability-review-2026-05-12.md`, `policy-baseline/README.md`,
`PRODUCTION-READINESS-CHECKLIST.md`, `aws-cost-analysis.md`.

---

## 1. Identity & Access

**SA RBAC scoping.** Custom workloads use namespaced SAs + Roles. Helm
components use chart defaults — unaudited. *Recommend:* `rbac-tool
who-can '*' '*'` quarterly, document any ClusterRole granting `*/*`.
**S**, $0.

**PAT rotation.** Multiple PATs (claude-cli, GH Actions, Flux deploy).
No cadence. *Recommend:* set 90d expiry on all PATs (GH native), add a
calendar reminder. **S**, $0.

**SSO for Grafana / kubectl.** Grafana admin secret; kubeconfig is the
admin cert. *Recommend:* **defer** — OIDC is operationally expensive
for one operator. Keep both in 1Password; document revocation.

**Workload identity (IRSA-style).** All in-cluster AWS access uses
long-lived static keys (Velero, kopia, backups, Barman). *Recommend:*
**defer** real IRSA — requires a publicly-reachable OIDC discovery doc,
non-trivial for a private cluster. Mitigate by keeping per-workload IAM
scoping (already done) + annual key rotation. **M** to rotate.

**Audit logging.** Kubespray `kubernetes_audit: true`, 30d on disk.
*Gap:* logs stay on CP nodes — no central collection or alerting on
suspicious verbs. *Recommend:* ship to Loki (§5), Prometheus rule on
"exec into prod ns". **M**, $0.

## 2. Network security

**Default-deny NetworkPolicies (Phase 2).** Designed, not applied.
Hubble observation window still pending. *Recommend:* land this —
biggest concrete gap. Start with `traefik`, `postgres`, `monitoring`.
**M**, $0.

**Egress controls.** Unrestricted today. *Recommend:* with Phase 2, add
namespace egress allowlists (DNS + known externals; e.g.
`home-automation` -> IoT VLANs, `backups` -> S3). **M**, $0.

**mTLS / service mesh.** *Recommend:* **skip** Istio/Linkerd. If mTLS
becomes important, enable `cilium.encryption.type=wireguard` (one flag,
no new component).

**DNS security.** Technitium on .50/.51. No DNSSEC validation on uplink;
no DoT/DoH. *Recommend:* enable DoT to Cloudflare/Quad9 + DNSSEC
validation in Technitium UI. **S**, $0.

**Public exposure (WAF / rate-limit / geo).** WAF has the 3 managed rule
sets + Plex bypass. No rate limit; no geo-block. *Recommend:* add a WAF
rate-based rule (2000 req / 5min / IP). Geo-block is risky for HA
mobile travel — leave off. **S**, ~$1-3/mo.

**Traefik security headers.** `traefik-values.yaml` has a TODO; no HSTS,
CSP, frame-options. *Recommend:* add a `secure-headers` middleware
(HSTS preload, X-Frame-Options DENY, Referrer-Policy strict-origin) as
`defaultMiddlewares` in TLSStore. **S**, $0.

## 3. Secrets

**SOPS state.** 16 policy files + ~14 encrypted payloads. *Recommend:*
pre-commit hook that greps tracked files for AKIA/BEGIN PRIVATE KEY and
checks every `*.sops.yaml` decrypts. **S**, $0 (see §8).

**Rotation cadence.** None formal. *Recommend:* annual calendar for AWS
keys (per workload), Flux deploy key, SOPS age key (with re-encrypt
script). **S** doc; **M** first run. $0.

**Etcd-at-rest.** Already on (kubespray v1.27+). One-time verify.

**Vault / Secrets Manager.** **Skip** — SOPS+git is fine at this scale.

## 4. Backups + DR

**Restore-test cadence.** No documented end-to-end restore since the
rebuild. *Recommend:* quarterly drill of postgres + HA + one PVC.
**M**, $0. **Highest-value DR item.**

**Cross-region copy.** Velero + Barman in us-west-2 only. *Recommend:*
S3 CRR on `velero.wind.etherport.net` + `postgres-barman.*` only.
**S**, ~$2-4/mo.

**Retention.** 30d Velero, ~30d Barman PITR. *Recommend:* extend Barman
base backups (not WAL) to 90d — postgres corruption may go unnoticed
for weeks. **S**, ~$0.50/mo.

**DR runbook.** `disaster-recovery.md`, `etcd-backup-restore.md`,
`postgres-barman.md` exist. *Gap:* no top-level "cold-start from zero
hardware" runbook (Proxmox -> Packer -> TF -> Kubespray -> Flux ->
restore). The post-bootstrap workflow is 80% of it. **M**, $0.

**RTO/RPO.** Implicit only. *Recommend:* declare per-tier targets in
`disaster-recovery.md` (Tier 1 HA/Plex: RTO 4h / RPO 24h; Tier 2 wiki:
RTO 24h / RPO 24h). **S**, $0.

## 5. Observability

**SLOs.** None. *Recommend:* declare 3 SLOs (HA, Plex, chat — 99%
monthly is fine) + multi-window burn-rate alerts. **S**, $0.

**Alert noise.** No documented FP review. *Recommend:* dump 30d from
Alertmanager, tune top-5 noisiest. **S**, $0.

**Distributed tracing.** Skip.

**Log aggregation (Loki).** Missing — logs die with pods. *Recommend:*
Loki + Promtail Helm release, 14d retention. **M**, ~$0.

**Long-term metrics.** Prometheus 15d. *Recommend:* bump to 30-45d if
disk allows, or remote-write to Grafana Cloud free tier (10k series).
Thanos/Mimir overkill. **S**, $0.

## 6. Reliability

**PDBs (Phase 3).** Deferred. *Recommend:* minimum-viable
`maxUnavailable: 1` on traefik, cert-manager, monitoring stack, CNPG.
**S**, $0.

**Autoscaling / spare capacity.** Fixed 4-worker + GPU; Proxmox doesn't
autoscale. Leave — sized for steady state.

**Probes.** Custom manifests (`route53-ddns`, `auto-remediation`) may
lack liveness/readiness. *Recommend:* one-shot jq audit, add where
missing. **S**, $0.

**Graceful shutdown.** *Recommend:* `terminationGracePeriodSeconds: 60`
+ preStop sleep on Traefik (CNPG handles its own). **S**, $0.

**PgBouncer.** CNPG `Pooler` CRD available. *Recommend:* defer until
connection counts demand it.

## 7. Compliance / housekeeping

**Image scanning.** None. *Recommend:* weekly Trivy cron over all
cluster images, notify on CRITICAL. **S**, $0.

**SBOM.** Skip.

**Dependency upgrades.** Renovate active and tuned. Good.

**Cost monitoring.** No AWS Budget. *Recommend:* TF-managed
`aws_budgets_budget` at $75/mo, 80%/100% to existing SNS topic. **S**, $0.

**Tags as policy.** Partial. *Recommend:* default `tags` block in each
TF module's `provider "aws"` (Owner, Project, Environment). **S**, $0.

## 8. Operational maturity

**Pre-commit hooks.** None. *Recommend:* `.pre-commit-config.yaml` with
`terraform fmt`, `tflint`, `yamllint`, custom `sops-secrets-check` (greps
for AKIA/private-key, validates `*.sops.yaml` are encrypted). **S**, $0.
High ROI.

**PR reviews.** Solo. *Recommend:* GH branch protection requiring CI
green before merge to `main`. **S**, $0.

**Drift detection.** *Recommend:* weekly scheduled GH Actions `terraform
plan` across modules, SNS on diff. **S**, $0.

**Change windows.** Skip.

---

## Top 10 quick wins (ranked)

Land roughly in this order; each is S effort unless noted.

1. **Backup restore drill** (postgres + HA + one PVC). The single
   highest-confidence-building thing you can do this quarter. M effort,
   $0.
2. **Phase 2 NetworkPolicies** (tier-1 namespaces, default-deny ingress
   + scoped egress). Biggest concrete security gap. M, $0.
3. **Traefik secure-headers middleware** as TLSStore default (HSTS,
   X-Frame-Options, Referrer-Policy). S, $0.
4. **AWS Budget alarm** at $75/mo via TF, SNS to existing topic. S, $0.
5. **Pre-commit hooks** (terraform fmt, yamllint, sops-secrets-check).
   S, $0. Prevents whole classes of mistakes.
6. **WAF rate-based rule** (2k req / 5min / IP). S, ~$1-3/mo.
7. **Tier-1 PDBs** (Traefik, cert-manager, monitoring, CNPG) — Phase 3
   subset. S, $0.
8. **DR cold-start runbook + RTO/RPO targets** in `disaster-recovery.md`.
   M, $0.
9. **Loki + Promtail** Helm release with 14d retention. M, $0. Unlocks
   audit-log alerting (§1) and post-mortems.
10. **Weekly TF drift detection** GH Actions cron with SNS on diff. S, $0.

Total budget impact: ~$1-5/mo (well within $60 ceiling). Total effort:
roughly 2-3 weekends of focused work, landable incrementally.

**Explicitly deferred** (not worth it at this scale): IRSA, service
mesh, Vault, SBOM, OIDC for kubectl/Grafana, distributed tracing,
node autoscaling.
