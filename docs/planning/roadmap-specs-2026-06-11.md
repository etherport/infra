> **Dated snapshot (2026-06-11; banner refreshed 2026-07-01).** Status of the three specs:
> **B1 (audit-log→Loki) ✅ shipped**; **C2/I7 (advisor right-sizing/cost) not built** (still valid);
> **A2 (3-2-1 offsite) NOT built and newly relevant** — it is now M111's architectural follow-up
> (velero primary BSL → local MinIO/Ceph RGW + batched Deep Archive), though this spec's
> us-east-1-replica design needs revisiting (the us-east-1 spoke was decommissioned 2026-07-01,
> M110; the request-cost findings of M111 favor local-first over cross-region replication).
> `outstanding-work.md` is the live status.

# Roadmap implementation specs — 2026-06-11

Ready-to-execute specs for the top Wave-2 [dev-roadmap](dev-roadmap-2026-06-11.md)
items: **B1** (audit-log→Loki), **A2** (3-2-1 offsite backups), **C2/I7** (advisor
proactive right-sizing/cost). Each was produced by an architect pass over the live
repo and surfaced real gotchas — captured below. Format mirrors `hardening-plan-2026-06-10.md`.

> **Doc bug found + fixed in this pass:** the README §Backups table had wrong bucket
> names — Velero uses `velero.wind.etherport.net` and CNPG Barman uses
> `postgres-barman.wind.etherport.net` (dedicated buckets), not `infra.../velero` &
> `infra.../postgres/barman`. README corrected 2026-06-11.

---

## B1 — Ship kube-apiserver audit log to Loki + baseline alerts  ·  Effort: S

**Goal:** the audit log is already written (`kubernetes_audit: true` → `/var/log/kubernetes/audit.log` on cp nodes) but dies on the node, never queried. Tail it into Loki via the existing Alloy DaemonSet + add detective alerts.

**Verified preconditions (good news):**
- Alloy DaemonSet **already tolerates control-plane nodes** (`alloy.yaml` — `node-role.kubernetes.io/control-plane` toleration) — no toleration change (the *opposite* of the Velero node-agent gotcha).
- `/var/log` is **already host-mounted** (`mounts.varlog: true`), and the audit file is under it; Alloy runs as uid 0 → can read the 0600 file. No mount/permission change. (Verify the mount during rollout in case a future chart narrows it.)
- Loki ruler + k8s-sidecar (`loki_rule: "1"` ConfigMaps) is live — LogQL alerts are the mechanism (PromQL can't query logs); model on `monitoring/05-loki-rules-ipmi.yaml`.

**Steps:**
1. **Alloy config** (`clusters/wind/helm-releases/alloy.yaml`, River block): add `local.file_match` + `loki.source.file` + `loki.process` for the audit path. **Cardinality discipline (critical):** promote ONLY `verb`, `resource`, `namespace` to labels; keep `user`/object-name/`sourceIPs` in the line body (labeling them blows up the Loki index). Drop `stage=RequestReceived` (halves volume). Use `requestReceivedTimestamp` for the log timestamp.
2. **Alerts** — new `monitoring/07-loki-rules-audit.yaml` (ConfigMap `loki_rule: "1"`) + register in `monitoring/kustomization.yaml`. Four LogQL `count_over_time(...) > 0` rules: (a) secret reads by principals **not** on a baselined known-SA allowlist; (b) pod exec/attach; (c) RBAC `escalate`/`bind`; (d) anonymous/`system:unauthenticated` **allowed** (relevant — `kube_api_anonymous_auth: true` + `remove_anonymous_access: false`).
3. (Optional) Grafana dashboard ConfigMap (`grafana_dashboard: "1"`, Loki datasource).

**Verify:** exec into a cp-node Alloy pod, `ls -l /var/log/kubernetes/audit.log`; confirm `{job="kube-audit"}` stream + that the label browser shows only verb/resource/namespace; **run each alert's inner LogQL and confirm non-empty during a deliberate test** (a wrong JSON field name = silent zero-match = false assurance); baseline the known-SA allowlist via `sum by (user)(...secrets...[24h])`; trigger `AuditPodExecAttach` by exec-ing into a pod.
**Rollback:** revert the Alloy block + remove the rules file (pure config; the on-disk audit log keeps being written).
**Top risk:** **audit volume vs the Loki cap** (20Gi PVC, 10MB/s ingest) — the default kubespray policy can be thousands of events/sec. Mitigations (drop RequestReceived + label discipline) are in step 1, but **measure after rollout**; if it threatens the cap, add a custom audit policy (kubespray re-run, its own sub-item) that sets `None` for noisy read verbs. Also: PII (usernames/IPs/object names) — Loki is internal-only; treat the stream as sensitive; keep Secrets at Metadata level.

---

## A2 — 3-2-1 / offsite backup posture  ·  Effort: M

**Goal:** all backups live in **one AWS account, one region (us-west-2)**. Add an immutable, offsite (us-east-1) copy of the critical tiers.

**Corrections surfaced (verify first):**
- Critical backups are in **dedicated buckets**, not `infra/...`: Velero → `velero.wind.etherport.net`, CNPG Barman → `postgres-barman.wind.etherport.net`, etcd snapshots ride *inside* Velero's `kube-system-daily`. (README fixed this pass.)
- **Object Lock can only be set at bucket creation** — cannot toggle on the in-use primaries. → **Option A (recommended): Object Lock on NEW us-east-1 *replica* buckets only**; primaries keep versioning. (Option B — new locked primaries + data migration — rejected: touches live backup targets.)

**Tier order:** (1) CNPG Barman first (live app state, only PITR path, smallest — pilot the pattern here); (2) etcd + Velero `kube-system-daily`; (3) Velero `critical-apps-daily` + `infrastructure-daily`. NOT first pass: the 7 NAS s3-syncs (source still on NAS), UDM dumps, archive/logs.

**Steps (all in `infra/terraform/aws/s3/`):**
1. `providers.tf`: add an `aws.replica` alias (region us-east-1).
2. `main.tf`: per critical bucket, a us-east-1 **replica bucket** created with `object_lock_enabled = true` + versioning + `object_lock_configuration` (**GOVERNANCE mode, 30d** — *not* Compliance: Compliance is irreversible, a footgun for a homelab; Governance + the existing `DenyBucketDestruction` policy + no `BypassGovernanceRetention` in CI covers the realistic threats) + SSE + public-access-block + `prevent_destroy`.
3. **Replication IAM service role** (`s3-backup-replication`, assumed by `s3.amazonaws.com`) with source-read + dest-write (incl. `s3:PutObjectRetention` for the lock).
4. `aws_s3_bucket_replication_configuration` on each **primary**: Barman whole-bucket; Velero **scope to critical prefixes** — but **verify the Velero key layout first**: Kopia PV-blob data is NOT under the per-backup prefix, so prefix-filtering risks replicating metadata without PV data (the exact `velero.yaml` L37-41 warning). **When in doubt, replicate the whole velero bucket.** `delete_marker_replication: Disabled` (never propagate deletes to the immutable copy).
5. Cost: replicate as `STANDARD_IES` (Standard-IA; *not* One-Zone — single-AZ unfit for DR); noncurrent-version expiry > the 30d lock window.

**Cost:** ~$4–5/month (dominated by inter-region transfer ~scaling with churn) + ~$1 one-time seed. Object Lock has no surcharge.
**Verify:** `terraform plan` shows **zero changes to primaries** (abort if either shows replacement); trigger a backup → replica object appears in us-east-1 within ~15 min; `get-object-retention` shows GOVERNANCE + RetainUntilDate; a hard `delete-object --version-id` is **AccessDenied** (WORM); confirm Velero replica includes Kopia repo data not just metadata.
**Rollback:** CRR + role are fully reversible (`terraform destroy -target=...`); **replica buckets can't be emptied until retentions lapse (≤30d)** even with `prevent_destroy` removed — needs `--bypass-governance-retention` (admin only, not CI). This friction is intended (and why Governance, not Compliance).
**H29 coordination:** the static CI principal needs `iam:CreateRole/PutRolePolicy/PassRole` added (scoped to the replication role) to apply this — `terraform-storage.json` already has the S3 replication/lock perms but no IAM-role-creation. This *widens* the long-lived-key blast radius → **raises H29's priority**; when H29 lands, the role + perms transfer cleanly. CRR itself uses the service role — **no new long-lived secret** introduced (a win).

---

## C2 / I7 — Advisor proactive weekly right-sizing + cost report  ·  Effort: M

**Goal:** the auto-remediation advisor is reactive-only. Add a scheduled weekly read-only report: right-sizing proposals (fixes L16's wild request:limit ratios) + a cost narrative — reusing the advisor's Claude/Prometheus/Loki/email plumbing.

**Key design decisions:**
- **Standalone CronJob, NOT a scheduled mode in the controller** — the controller is deliberately single-threaded (a multi-minute weekly Claude call would block alert remediation + `/approve` webhooks). Model on `monitoring/service-status-report/` (the near-exact precedent: python CronJob, script-in-ConfigMap, Prometheus+Alertmanager HTTP + SES email, no K8s RBAC).
- **Reuse patterns, not code:** lift the self-contained helpers from `controller-configmap.yaml` verbatim — `_call_anthropic` (single-shot, L1174-1212), `_add_cost`+pricing, the email stack (`_EMAIL_CSS`/`_render_email`/`_send_email`), `_fetch_loki_window`. Do NOT import the controller (it carries RBAC/SSH/approval machinery a read-only report must not have).
- **New permission-free ServiceAccount** (`rightsizing-report`, zero Roles) — do **not** reuse the controller SA (H32 just narrowed it; reusing would re-grant mutate verbs + couple the workloads). The report only does HTTP GETs + SMTP → needs no K8s API. This *structurally* enforces read-only-first.
- **Place in the `auto-remediation` namespace** to reuse the existing `ai-advisor-anthropic-key` / `ai-advisor-smtp` SOPS secrets (secrets are namespace-bound; `monitoring` would force duplicating the Anthropic key). No new namespace = no PSS-label change.

**PromQL (instant queries with `[14d:5m]` subqueries):** P95 + max `container_memory_working_set_bytes` vs `kube_pod_container_resource_requests/limits` per (namespace,pod,container); same for CPU. Two `topk` lists — over-provisioned (request ≫ P95) and under-provisioned/OOM-risk (P95/request high) + a `limit/request > 2` "wild ratio" flag (the ollama case). Two-pass to bound cost: cheap ranking query → detail only for the topk names.

**Claude output:** strict-JSON schema (validate + drop unknown fields) — `summary` + `rows[]` with current/observed_14d/recommendation/rationale/confidence/`suggested_action`. `suggested_action` is **advisory text only** in phase 1.

**CronJob:** `python:3.14-slim`, Mondays 07:00 PT (`timeZone: America/Los_Angeles`, avoid the 03:00-04:00 CNPG window), `concurrencyPolicy: Forbid`, secret refs for Anthropic + SMTP. Add `AI_REPORT_MAX_USD=0.25` per-run guard (estimate input tokens, ship metrics-only table if over). New dir `platform/kubernetes/rightsizing-report/` (configMapGenerator for script + prompt), wired into `clusters/wind/kustomization.yaml`.

**Cost narrative (gated, best-effort):** (a) Anthropic token spend from the advisor's own Loki audit log (`{namespace="auto-remediation"} | json | tag="ai_advisor" | event="success"` → sum `cost_usd`) — no new perm. (b) AWS Cost Explorer — **`ai-advisor-readonly` lacks `ce:GetCostAndUsage`** (CloudWatch-Logs-only); needs a Terraform IAM addition + secret repopulate → **defer cost-(b) to a follow-up** (widens those creds); script silently omits it on AccessDenied.

**Verify:** dry-run the PromQL via port-forward (confirm the ollama ratio shows); `kubectl apply --dry-run=server -k ...`; one-off `kubectl create job --from=cronjob/...` test → email arrives, validator drops nothing.
**Rollout:** Phase A advisory report only (token cost ~$0.20/mo); Phase B cost-(b) after the IAM change; **Phase C (future, separate)** opt-in actions routed through the controller's *existing* HMAC approve-via-email path + `bump_resource_request` executor (50%/bump cap) — behind a default-off `AI_RIGHTSIZE_ACTIONS_ENABLED` flag. Never autonomous.

---

## Cross-cutting notes
- **All three are safe to author as IaC; none should be applied unattended** — B1 touches the live Alloy config (log-shipping risk + volume), A2 makes real AWS/IAM changes, C2 deploys a new workload + needs the report tuned over 2-3 runs. Do supervised.
- **Sequencing:** B1 first (cheapest, security-foundational). A2 raises H29's priority (adds IAM-role-creation to the CI key). C2 Phase-A is independent + reuses everything.
- These fold into the roadmap tracks; mark ✅ in `dev-roadmap-2026-06-11.md` as they land.
