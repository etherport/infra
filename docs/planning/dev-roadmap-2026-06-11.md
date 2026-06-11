# Dev Roadmap — 2026-06-11

Forward-looking "what to build next" for the `wind` homelab, distinct from the
security **hardening hit list** (H3/H29–H34 in `outstanding-work.md`). Synthesized
from a 4-track review (reliability/DR/observability · security maturity ·
platform/capabilities · devex/automation/cost). Items fold into existing tracker
IDs where one exists (M/L/C). Effort: S ≈ hours, M ≈ a day or two, L ≈ multi-day/HW.

## How to read this
The four tracks below each carry their own prioritized items. Several items
**recurred across tracks** — those are the highest-confidence bets, pulled up into
"Do first." A unified sequencing table is at the end.

---

## ⭐ Do first — cross-cutting, high value-per-effort

1. ✅ **Flux manifest validation CI** *(devex I1; S)* — **LANDED 2026-06-11** (`.github/workflows/flux-validate.yml`) — the biggest correctness gap: every Terraform stack gets a PR `plan`, but the **43 kustomizations + 13 HelmReleases reconcile straight off `main` with no pre-merge check** — and a typo in `clusters/wind/kustomization.yaml` freezes *all* Flux reconciliation (the exact H32 hazard). Add `.github/workflows/flux-validate.yml`: `kustomize build` every overlay → `kubeconform`. **First step:** loop `kustomize build` over `find platform clusters -name kustomization.yaml` on PR. *(This session already relies on `kubectl kustomize clusters/wind` as a manual gate — automate it.)*
2. **CI AWS auth → OIDC** *(= H29; M)* — already the "highest-ROI hardening"; also a **devex enabler** — every new automation (cost collector, CI metrics) otherwise needs another long-lived key. Stack designed in `hardening-plan-2026-06-10.md`; bootstrap needs admin creds.
3. **kube-apiserver audit log → Loki** *(security S1; S)* — the audit log is *already written* (`kubernetes_audit: true`) but dies on the node, never queried. One Alloy scrape job + a few LogQL alerts (secret reads, exec/attach, RBAC escalate) = SIEM-lite on the stack you already run. Forensic substrate before more advisor autonomy.
4. **AI-advisor → proactive ops (right-sizing + cost report)** *(capabilities C2 / devex I7; M)* — the advisor (18 actions, deep-mode, cross-session memory, **`bump_resource_request` already an action**) only fires reactively. A scheduled CronJob reusing its Claude+Prometheus+email plumbing → weekly right-sizing proposals (fixes L16's wild request:limit ratios) + cost narrative. Near-zero new infra.
5. **Taskfile ops entrypoint** *(devex I3; S)* — the README's "How to apply changes" is a CLI spec in prose. A root `Taskfile.yml` wrapping the `gh workflow run …` incantations + `scripts/` makes ops discoverable (`task --list`) and rebuild/onboarding-friendly.

**Trivial quick wins (code already shipped):** finish **unifi-poller** (C7/M55 — staged, needs a UniFi account + secret); execute the **Phase-3 alert opt-in cadence** (L13/C2a — one `ai_remediation: "auto"` label/week); **Twilio 911 address** (M15 — a *safety* item, should outrank hygiene).

---

## Track A — Reliability / DR / Observability

| # | Initiative | Effort | Notes |
|---|---|---|---|
| A1 ★ | **Execute the RTO/RPO drill rotation** (folds M11/M12) — the DR plan's RTO/RPO cells are all `?`/never-drilled; backups are unvalidated (the recent Velero 4-day PartiallyFailed proves "backup OK ≠ restore works"). Start with non-destructive Velero/CNPG restore drills; add a restore-recoverability alert. | M | first step: run the §11 Q1 drill verbatim, fill one real row |
| A2 ★ | **3-2-1 offsite posture** — every backup (Velero/Kopia, CNPG Barman, 7 S3-syncs) lands in **one AWS account, one region**. Add S3 cross-region replication + Object Lock/versioning for the critical tier (etcd, Barman, Velero infra). | M | coordinate with H29 so it's wired with scoped creds; in `infra/terraform/aws/s3/` |
| A3 ★ | **SLOs + error budgets + burn-rate alerts** — no objective "healthy enough"; every alert is equal-urgency and the advisor burns tokens on noise. Define SLOs for DNS/ingress/CNPG/API from existing `probe_success`+Traefik metrics (Sloth or hand-written rules). | M | first SLO = DNS availability, new `monitoring/07-slo-dns.yaml` |
| A4 | **Multi-node Proxmox HA** (= L1) — single PVE host is the largest physical SPOF; the DR runbook's "clustered Proxmox" branch is written but untrue. | L | HW-gated (2nd node); Ceph already external on VLAN 210 |
| A5 | **Distributed tracing** (Tempo + OTLP via existing Alloy) — zero tracing today; reuses Alloy+Grafana+S3 pattern. | M | app instrumentation is the long pole (cue-api cross-repo) |
| A6 | **Synthetic user-journey probes** — extend blackbox beyond reachability to correctness (DNS returns *right* answer, Grafana login, CNPG `SELECT 1`). Catches silent functional regressions (cf. the Plex `allowedNetworks` bug). | S–M | reuses blackbox-exporter |
| A7 | **Status page** (Gatus, Tailscale-served) — live health view beyond the daily email. | S | quick QoL win |
| A8 | **Chaos / failure-injection** — validate VRRP failover, pod reschedule, the advisor actually fire. | M | sequence after A1 + A4 |
| A9 | **Capacity prediction + observability-data DR** — `predict_linear` alerts for Ceph/Loki fill (Loki has a cap, no pre-alert); Prometheus has no long-term store. | M | |

## Track B — Security maturity (beyond H3/H29–H34)

| # | Initiative | Effort | Notes |
|---|---|---|---|
| B1 ★ | **Audit log → Loki + alerts** (= Do-first #3) | S | `alloy.yaml` scrape job |
| B2 ★ | **Policy-as-code admission control (Kyverno, audit-first)** — PSS gives a `baseline` floor but can't express image provenance / required digests / registry allowlists. Kyverno makes H30's pinning a hard admission gate + is the enforcement engine for B3. | M | after/with H30; `validationFailureAction: Audit` first |
| B3 ★ | **CI image scan + SBOM + signing (Trivy + syft + cosign)** — zero scanning today; in-house images ship floating tags. Keyless cosign rides H29's OIDC; Kyverno `verifyImages` enforces at admission → real supply-chain integrity. | M | prereq H29 + H30 |
| B4 | **Runtime security (Cilium Tetragon, observe-first)** — adds the L7/process/syscall layer Hubble (flow) + Kyverno (admission) leave open. eBPF substrate already present. | M | after H3 |
| B5 | **SSO / zero-trust for internal UIs** — only `approve.etherport.net` has SSO (CF Access); Grafana is admin-password-only; resolves L14 (advisor public-approval-URL auth gap). | M | extend CF Access to Grafana, or Tailscale Funnel |
| B6 | **Automated secret rotation** — turn H33's runbook into scheduled rotation for the mechanizable secrets (gh-runner token, Grafana pw) + secret-age alerting. | M | after H33 |
| B7 | **Supply-chain attestation / SLSA provenance** — capstone once B2+B3 exist; Kyverno requires signature *and* provenance from `repo:sparked-diamond/infra`. | M | after B2+B3 |
| B8 | **East-west encryption (Cilium WireGuard mode)** (= M66) — pod-to-pod is cleartext + (pre-H3) unrestricted; mTLS-without-a-mesh, far lighter than Istio. | M | validate MTU vs the 9000 Ceph VLAN |

## Track C — Platform / capabilities

| # | Initiative | Effort | Notes |
|---|---|---|---|
| C1 ★ | **Templatize the `cue` app pattern (PaaS-lite)** — `cue-api`+`cue-db` already encode the full "new app" recipe (CNPG DB + ghcr image + drizzle init + Tailscale/cloudflared routing). Make it a kustomize component / scaffold so a new app is "fill in name/image/routes". Eliminates the class of bug behind the dangling `cue-api` ImagePolicy. | M | pairs with M64 |
| C2 ★ | **AI advisor maturation** — cross-system actions (dispatch `gh workflow run` for tf/ansible; extend Tier-3 SSH to PVE), new action types, a "supervised-auto" tier, a cheap **local-LLM Tier-0 triage** (C9, reuses the idle P40 ollama → cuts token spend). | M (incremental) | **cross-system actions now unblocked** — H32 RBAC scoping is done |
| C3 ★ | **Identity/SSO + external-secrets** — biggest *structural* gap: **no IDP and no external-secrets anywhere**. Stand up Authentik/Dex (single SSO for Grafana/open-webui/wikijs/future apps) + an external-secrets operator (narrows H33's single-age-key blast radius). | L | resolves L14; makes C1 auth-by-default |
| C4 | **GitOps-snapshot framework for UI-managed appliances** — generalize the M48 UNAS snapshot+drift pattern across Protect/UDM-BGP/Talk; diff live vs git like the TF drift detector. | M | per appliance |
| C5 | **Cost dashboard** (= devex I6/C8) | S/M | quick-ish |
| C6 | **Home-automation depth + data/analytics** — HA→Prometheus sensor bridge; query cue(health)+cost+UniFi data. | M | consumer of C1/C5/C7 |
| — | **unifi-poller finish** (C7/M55), **Twilio 911** (M15), **Proxmox HA** (= A4/L1) | S/S/L | |

## Track D — DevEx / automation / cost

| # | Initiative | Effort | Notes |
|---|---|---|---|
| D1 ★ | ✅ **Flux validation CI** (`.github/workflows/flux-validate.yml`, landed 2026-06-11) — `kustomize build` all 44 overlays + kubeconform on the rendered root | S | done |
| D2 | **Conftest/policy tests on rendered manifests** — encode house rules as CI tests (every ServiceMonitor has `release: monitoring`; no `:latest`; requests set). On-ramp to Kyverno (B2). | M | builds on D1 |
| D3 ★ | **Taskfile entrypoint** (= Do-first #5) | S | |
| D4 | **CI gitleaks + pre-commit-in-CI** — pre-commit is client-side only (M60); the mini auto-pushes to `main` with no branch protection (L20). Server-side gate closes it. | S | |
| D5 | **CI/CD observability** — 38 workflows + a single self-hosted runner with "intermittent SSH", no success-rate/duration/runner-health view. GH-API CronJob → pushgateway → Grafana. | M | |
| D6 ★ | **Cost visibility** — clone the `cloudwatch-to-loki` boto3 CronJob → AWS Cost Explorer → Prometheus/Grafana + a monthly delta in the status-report email; Anthropic token-spend from the advisor's Loki audit log. | M | scoped Cost Explorer IAM (reuse `ai-advisor-readonly`) |
| D7 | **Doc automation** — link-check + staleness detection + auto-index for the 137 docs (M68 is a manual treadmill). | S→M | lychee link-check is the quick win |
| D8 | **PR plan/diff rollup** — 25 near-identical TF plan-comment blocks → one composite action + a unified rollup comment (tf plan + manifest diff + policy results). | M | after D1/D2 |
| D9 | **Bootstrap-from-scratch automation** — chain packer→proxmox TF→kubespray→Flux→SOPS into one `task bootstrap`, capturing the UI-only manual steps (UNAS NFS ACL, UDM BGP, unifi accounts) as explicit prompts. | L | after D3 |

---

## Unified sequencing

**Wave 1 — now, cheap, unblock everything (all S except H29):**
D1/A-quickwins (Flux validate CI), D3 (Taskfile), D4 (CI gitleaks), B1 (audit→Loki), + the trivial wins (unifi-poller, Phase-3 cadence, Twilio 911). **H29 (OIDC)** as the foundational credential cleanup.

**Wave 2 — high-leverage, reuse existing assets:** C2/I7 (advisor proactive right-sizing/cost) + D6 (cost collector); A1 (drill rotation) + A2 (3-2-1); A3 (SLOs).

**Wave 3 — hardening-as-code:** B2 (Kyverno) + D2 (conftest) + B3 (scan/SBOM/sign) compose into supply-chain integrity; B5 (SSO).

**Wave 4 — structural bets:** C1 (app template), C3 (IDP + external-secrets), B4 (Tetragon), A5 (tracing), D5 (CI/CD obs).

**Backlog / HW-gated:** A4/L1 (Proxmox HA), C4 (appliance snapshots), A8 (chaos), D9 (bootstrap), C6 (analytics).

**Notable dependency now cleared:** C2's cross-system advisor actions were gated on scoping the auto-remediation RBAC — **H32 landed 2026-06-11**, so that ordering constraint is satisfied.

---
*Source: 4 parallel architect reviews, 2026-06-11. Full per-track detail (every item's why/first-step) was distilled here; this doc is the durable record.*
