# Session Log — narrative history

Append-only, **newest first**. One entry per substantive working session: what was
done, **why** (decisions/rationale that the code alone won't tell you), the state at
end, and explicit next steps. This is the artifact for resuming work if the chat
history is lost or you're picking up on a different machine.

**Maintenance:** add an entry at the end of every substantive session (see
[`../../CLAUDE.md`](../../CLAUDE.md) §6). For the structured, ID'd to-do status, see
[`outstanding-work.md`](outstanding-work.md). Pre-2026-06-14 session history lives in
that tracker's "Recently completed" blocks and the dated planning docs
(`gcp-oidc-wif-l21.md`, `cloudflare-provider-v5-migration.md`, etc.).

---

## 2026-06-17 — CNPG webhook cert wedged Flux (caBundle/serving-cert mismatch) — fixed

**Surfaced while applying M62:** the flux-system Kustomization went `Ready=False`, blocking
ALL GitOps — `ScheduledBackup/cue-db-daily dry-run failed: failed calling webhook
"mscheduledbackup.cnpg.io": ... tls: failed to verify certificate: x509: certificate signed
by unknown authority`. The CNPG admission webhook was down → Flux couldn't apply CNPG
resources → couldn't advance past `0f43c36`.

**Root cause (tail of the 06-16 duplicate-operator incident):** during yesterday's operator
handoff/leader-churn, `cnpg-ca-secret` + `cnpg-webhook-cert` were regenerated (~12h before),
but inconsistently — the webhook configs' `caBundle` held the OLD CA, and the serving cert
was signed by yet another CA key (`ECDSA verification failure ... verifying ... cnpg-ca-secret`).
So CA secret, serving cert, and caBundle were three-way out of sync. The running operator
never self-healed it.

**Fix (owner-authorized, two steps):** (1) patched the webhook `caBundle` from `cnpg-ca-secret`
— necessary but INSUFFICIENT (serving cert was signed by a different/old CA). (2) **deleted
`cnpg-webhook-cert` + `kubectl rollout restart deploy/cnpg-cloudnative-pg`** → operator
re-issued a consistent serving cert + re-patched the caBundle on startup ("Updated current TLS
certificate"). Webhook dry-run then succeeded; Flux advanced to `c9b64de` `Ready=True`;
operator stable (`restarts=0`). DB clusters unaffected throughout (webhook only gates CNPG
resource admission; per-cluster Postgres TLS is separate).

**Durability:** the operator now owns a consistent, self-managed cert chain (its normal job;
the break was a one-time handoff glitch). The caBundle can't be static IaC (operator-injected
at runtime). Filed follow-ups: **H36** (Flux reconciliation alerting — gotk metrics are NOT
scraped today, so this silent wedge was found only by luck) and a note to evaluate
cert-manager-managed CNPG webhook certs (ca-injector = truly self-healing caBundle).

**Lesson:** after a CNPG operator change, verify the webhook works
(`kubectl -n <ns> get cluster <c> -o yaml | kubectl apply --dry-run=server -f -`) — cert
inconsistency is silent until the next admission call / Flux apply.

---

## 2026-06-16 — M62 authored: etcd snapshots → offsite S3 + freshness alert

**Goal:** close the etcd-backup DR gap — snapshots were local-disk-only, offsite solely
via the fragile Velero `kube-system-daily` path, no freshness alert.

**Authored (validated; applies are supervised — see outstanding-work M62):**
- **TF** `infra/terraform/aws/s3/`: new dedicated **`etcd-snapshots.wind.etherport.net`**
  bucket (STANDARD, 30d, versioned, PAB) + scoped **`etcd-backup`** IAM user (PutObject-only),
  mirroring the `postgres_barman` pattern. `terraform validate` clean.
- **Playbook** `etcd-backup.yml`: awscli + scoped creds on cp nodes; `etcd-snapshot.sh` now
  `aws s3 cp`s each snapshot offsite + pushes freshness/size/upload metrics to Pushgateway
  (pinned ClusterIP `10.43.32.171`).
- **Alert** `monitoring/06-backup-alerts.yaml`: `EtcdSnapshotStale` + `EtcdSnapshotS3UploadFailing`.

**Key design call:** used a **dedicated Standard-storage bucket, NOT the `archive` bucket** —
`archive.wind.etherport.net` transitions to Glacier Deep Archive after 2 days (~12h retrieval),
which would prolong a control-plane outage during a restore. Owner flagged a recurring habit
of defaulting new tasks to the archive bucket → added a loud "s3-sync cold storage ONLY"
warning at the bucket's TF definition + a memory note. **Rule: archive bucket = s3-sync cold
storage only; anything needing timely retrieval gets its own Standard bucket (like barman, etcd).**

**Validation:** TF validate ✅; PrometheusRule server-dry-run ✅ (the `unknown field "sops"`
errors in the kustomize dry-run are pre-existing SOPS secrets, Flux-decrypted, not ours);
playbook YAML + `--syntax-check` ✅. Pushgateway ClusterIP pinned to its current value so the
Flux helm-upgrade is a no-op on the immutable field.

**Next (supervised):** terraform apply s3 → SOPS the etcd-backup key into
`playbooks/secrets/etcd-backup.sops.yaml` → run `etcd-backup.yml --limit kube_control_plane`.
Flux ships the alert + pushgateway pin.

**✅ COMPLETED 2026-06-17 (all via CI):** terraform applied (`terraform-s3.yml`; one
invalid-tag-char retry), SOPS secret created, playbook ran (`ansible-vm-fleet.yml`). Hit two
node wrinkles: (1) the unrelated CNPG webhook-cert incident briefly wedged Flux (fixed — see
the 06-17 entry); (2) Ubuntu 24.04 dropped the `awscli` apt package → switched to the AWS CLI
v2 official sha256-pinned installer. **Verified end-to-end:** 3 CP-node snapshots in
`s3://etcd-snapshots.wind.etherport.net/<host>/` (~205MB each); Prometheus shows
`etcd_snapshot_last_run_timestamp` (fresh), `_s3_upload_success=1`, `_size_bytes` for all 3;
alerts live. L15 superseded.

---

## 2026-06-16 — CNPG operator restart-loop (duplicate operator) — fixed

**Trigger:** AI advisor email — "cloudnativepg pod is stuck." Full system check requested
after the 06-15 Cilium/NetworkPolicy work.

**System was healthy** except the operator: 8/8 nodes Ready, Flux all-Ready, both CNPG
clusters healthy (postgres-cluster 3/3, cue-db 1/1), Cilium audit mode still `Enabled`
(06-15 work intact, NOT enforcing — ruled out as the cause).

**Root cause (pre-existing, NOT from 06-15):** **two** CNPG operator deployments in
`cnpg-system` both running `controller --leader-elect` against the **same lease**
(`db9c8771.cnpg.io`):
- `cnpg-cloudnative-pg` — canonical, Helm/Flux-managed (`helm-releases/cnpg.yaml`, chart
  0.22.1); backs `cnpg-webhook-service`.
- `cnpg-controller-manager` — **orphan** from a pre-Helm raw-manifest install (no Helm/Flux
  labels, not in git, doesn't back the webhook service).
They fought over the lease → the loser hit `Put .../leases/...: context deadline exceeded`
→ `leader election lost` → exit/restart, repeatedly (37 + 29 restarts). Leases 34d old =
chronic. DBs unaffected (operator absence doesn't stop running Postgres).

**Fix:** `kubectl -n cnpg-system delete deployment cnpg-controller-manager` (owner-approved;
the Claude Code auto-mode classifier blocked it until the owner named the resource
explicitly). Helm operator immediately acquired the lease uncontested (lease holder now
`cnpg-cloudnative-pg-…`), started its controllers, restarts stopped climbing (held at 37),
webhook endpoint ready. Both clusters healthy. **Residual (harmless):** orphan
`ServiceAccount/cnpg-manager` (+ likely a cluster-scoped `cnpg-manager` Role/Binding) from
the old install — unused, low-priority cleanup (tracker).

**Why the AI advisor gave no remediation button (owner asked):** by design. The advisor's
prompt (`auto-remediation/advisor-prompt-configmap.yaml`) lists `cnpg-system` under *NEVER
PROPOSE* ("the executor allowlist excludes flux-system/kube-system/cnpg-system/rook-ceph/
cert-manager — proposals silently dropped"), so even with Phase 2/3 enabled it can only
**advise** (email) on cnpg-system, never offer an approve/auto action. Also "delete a
deployment" / "pick which duplicate operator is the orphan" isn't in its action whitelist
(restart_pods, scale, rollback_deployment, cnpg_recreate_replica, backups, …) and needs
human judgment. Working as intended — critical stateful namespaces are human-in-the-loop.

**Next:** confirm restarts stay at 37 (single operator = no contention); optional cleanup of
the orphan `cnpg-manager` SA/RBAC.

---

## 2026-06-15 — H3 NetworkPolicies Phase-1 + Cilium incident (kubespray cni-owner)

**Goal:** start H3 (default-deny NetworkPolicies). Authored Phase-1 manifests, hit a
contained Cilium incident enabling audit mode via kubespray (recovered), then enabled
audit mode the surgical way + made it IaC-durable + **started observation on postgres**.
**End state: audit mode ON (8/8 agents), NetworkPolicies live via Flux under audit,
postgres labeled (audit-both), helm release clean, cluster healthy.**

**What shipped (good):**
- `platform/kubernetes/networkpolicies/` (commit `3c299d9`) — default-deny + universal
  allows (DNS via host/remote-node:53 for link-local nodelocaldns, kube-apiserver, host,
  monitoring scrape) + `postgres-ingress` tier. Per-ns opt-in via `netpol.wind/enforced`
  label. **Inert** (not Flux-wired). All 5 validate vs live Cilium 1.18.6 CRDs.

**The incident (root cause + recovery — don't re-walk this):**
- To enable `policy-audit-mode`, ran kubespray `cluster.yml --tags=cilium,download` (v2.30,
  via a freshly-bootstrapped `~/.kubespray-venv` since the mini had none; system ansible
  2.21 is too new — kubespray needs 10.7.0/core-2.17). The run "succeeded" (exit 0) but a
  follow-up `kubectl rollout restart ds/cilium` (needed because audit-mode is read only at
  agent startup) put 2 agents into **`Init:CrashLoopBackOff`**.
- **Root cause:** kubespray's "Create cni directories" task chowns `/opt/cni/bin` to
  `kube_owner` (**`kube`** — set in `k8s-cluster.yml`). Cilium's `mount-cgroup` runs as
  root with `drop:[ALL]` (no DAC_OVERRIDE) → can't write `cilium-mount` to a kube-owned
  dir → `cp ... Permission denied`. **Latent** — the 6 un-restarted agents kept running off
  loaded eBPF (nodes stayed Ready); only restarted agents crashed. Confirmed via `/opt/cni/bin`
  **ctime = today 17:22** (chown updates ctime, not mtime — mtime still read Jun 5).
- **Misstep:** first tried `helm rollback cilium 13` (thinking the v2.30 chart changed the
  init container). It didn't help — rev-13's `mount-cgroup` securityContext is **identical**;
  the chart was never the cause. The rollback left a **`failed` helm rev 15** (release
  health still needs cleanup — see below) and reset `policy-audit-mode=false`.
- **Actual fix:** `chown root:root /opt/cni/bin` on all 8 nodes (the existing
  `pre-flight.yml` already enforces this — kubespray's cluster.yml had undone it) + delete
  the crashing pods. One node (k8s-w1) was missed on the first pass (truncated output) →
  always verify ALL nodes. Final: **8/8 agents Running (restart 0), 8/8 nodes Ready**,
  audit mode `Disabled` (= original safe baseline).

**Codified + documented (this entry's commit):**
- Strengthened `inventory/pre-flight.yml` comment (CRITICAL: re-run after any cluster.yml).
- Reverted the staged `cilium_policy_audit_mode` kubespray var (footgun) with a note to use
  the ConfigMap path instead.
- New runbook `docs/runbooks/cilium-cni-dir-owner.md` (symptom/cause/recovery + the actual
  kubespray run path, since `kubespray.sh` is stale). CLAUDE.md §5 gotchas updated.

**Audit mode ENABLED + made IaC-durable (later same day):**
- Enabled live via the **surgical path** the owner authorized: `kubectl patch cm cilium-config
  policy-audit-mode=true` + `kubectl rollout restart ds/cilium`. Rolled clean (dir is root-owned);
  **runtime `PolicyAuditMode: Enabled` on all 8 agents**, 8/8 nodes Ready. (helm rollback to
  rev 14 was the cleaner route but the auto-mode classifier blocked it as out-of-scope.)
- **Durability (owner: "don't let a future kubespray run overwrite these"):** (1) NetworkPolicies
  are Flux-managed → kubespray-safe. (2) `cilium_policy_audit_mode: true` committed to the
  kubespray inventory (source of truth → a kubespray render keeps audit on). (3) `kubespray.sh`
  wrapper rewritten (correct venv/inventory paths + **auto-runs `pre-flight.yml` after
  cluster.yml/upgrade/scale**, restoring `/opt/cni/bin` root owner) — so a kubespray run no
  longer breaks Cilium *when run via the wrapper*. (4) Backstop armed: `cilium_extra_values`
  adds `DAC_OVERRIDE` to Cilium `mount-cgroup` so it tolerates a kube-owned cni dir even on a
  raw kubespray run (not yet validated live — needs a kubespray render; tracked H35).
- `kube_owner: root` was **rejected** — `/etc/kubernetes` + `/etc/cni/net.d` are genuinely
  kube-owned, so flipping it would broadly re-chown system paths.

**Completed (owner said "start H3 and get this fixed now, OK to roll Cilium"):**
- **NetworkPolicies wired into Flux** (`clusters/wind/kustomization.yaml`, commits `4005fed`+`00bdb81`).
  Removed the standalone default-deny CCNP — Cilium's operator rejects an empty-rule policy
  ("rule must have at least one of Ingress/Egress/..."); instead the `allow-*` CCNPs (which
  select enforced namespaces + cover both directions) establish default-deny per Cilium's
  selection semantics. 3 allow CCNPs + `postgres-ingress` all `VALID: True`.
- **Observation STARTED on postgres** — endpoint is `POLICY (ingress/egress): Disabled (Audit)`.
  ⚠️ **Label must be in the namespace MANIFEST in git** (`cnpg/00-namespace.yaml`), not a
  `kubectl label` — Flux SSA strips out-of-band labels on reconcile (hit this; fixed via git,
  commit `7e83047`). `scripts/cilium/audit-report.py` reports cluster-wide AUDIT flows via the
  hubble relay for enforced namespaces. First run: 1 AUDIT flow (intra-postgres TCP — likely
  CNPG instance comms beyond :5432; investigate + add to the postgres allowlist). Recurring
  check set up via `/loop` on the mini session.
- **Helm release cleaned** — `helm rollback cilium 14` (rev 14 = audit=true) → clean
  `deployed` rev 16, supersedes the `failed` rev 15. Audit still Enabled on all 8 agents.

**Next (the multi-week observation phase):**
- Watch `hubble observe --namespace postgres --verdict AUDIT` (cover the CNPG backup/cron
  paths). Refine the postgres allowlist from real flows, then ENFORCE postgres (it's already
  in audit; the switch is disabling audit for it — but global `policy-audit-mode` is
  cluster-wide, so enforcement = keep audit on elsewhere and verify postgres' allowlist is
  complete before the final global audit-off).
- Then label the next tier (cue → dns → traefik → monitoring), writing each `1x-tier-*`
  allowlist from audit data. Exclude wireguard/kube-system/flux-system.
- **H35 follow-ups remain:** validate the `cilium_extra_values` DAC_OVERRIDE backstop on the
  next supervised kubespray run; review `setup.sh`.

---

## 2026-06-15 — H33a: offline backup age recipient + repo-wide re-key

**Goal:** close H33's single-key blast radius — one age recipient decrypted every
`*.sops.yaml`, with no offline backup (lose/rotate it wrong → whole estate
undecryptable). Add a second, **offline-only** recipient.

**What landed:**
- Owner generated a backup age keypair **on the laptop** (never on the mini); private
  half → 1Password "Homelab SOPS Age Key (BACKUP)" + paper in the safe. Public key
  `age1phcmcgfeqr66t7kxdafckp860y67j6n6y2qrn76hk4fm2vd59pxsqr3466` handed to me.
- Added it (comma-joined, **primary kept first**) to all **15** `.sops.yaml` (5 root
  `creation_rules` + 14 nested), then `sops updatekeys -y` across all **39** secret
  files. **Guardrail:** re-keyed one file → verified it still `sops -d`s with the
  primary → then batched the rest. Final verify: 39/39 carry **both** recipients,
  0 decrypt failures, no plaintext leaked.
- **No Flux/CI/GH-secret change** — the primary stayed a recipient throughout, so the
  three online holders (mini disk, GH `SOPS_AGE_KEY`, Flux `sops-age`) keep working;
  zero lockout window. The backup is pure offline break-glass.

**Why this design (vs rotating the key):** H33a is *additive* redundancy, not a
rotation. Adding a recipient + `updatekeys` only needs the **primary private** key (to
decrypt, already on the mini) + the backup **public** key (to add). The backup
*private* key never has to touch the mini — which is why I could run the mechanical
re-key here despite this session being on the mini.

**Pre-existing bug found + fixed (now L22):** `tailscale/01-oauth-secret.sops.yaml`
had a **MAC mismatch** — its encrypted body had been hand-edited outside `sops` (sops
`lastmodified` 2026-04-12), so it hadn't decrypted for ~2 months, undetected (the live
operator kept running off the pre-corruption apply). Confirmed pre-existing by the
identical failure on `git show HEAD:`. Fixed by pulling the good `values.yaml` from the
live `flux-system/tailscale-operator-oauth` secret (33d, the helm `valuesFrom` source)
into a temp file — **never printed** — rebuilding the manifest, and `sops -e -i`'ing it
clean (both recipients, valid MAC). Verified by **sha256 equality** with the live
value (`d1a0841e…`), not by dumping contents. Added **L22**: a CI/pre-commit check that
every `*.sops.yaml` actually decrypts, so a broken MAC fails fast next time.

**Docs updated:** `.sops.yaml` header (names both keys + re-key note), `secrets-rotation.md`
(H33a marked done + blast-radius table), `headless-ops-host.md` + `SOPS-SETUP.md`
(PRIMARY/BACKUP naming), `outstanding-work.md` (H33 → (a) done, (b) FileVault + (c)
split remain; new L22). 1P: rename the existing primary item → "Homelab SOPS Age Key
(PRIMARY)" (owner).

**State:** committed + pushed; Flux reconciled clean (in-cluster decrypt confirmed).
**Next:** H33 remainder is owner-only — **FileVault on the mini** (un-passphrased key
on disk) + optional per-domain recipient split. Then the other HIGH items: H3
(NetworkPolicies), H30 remainder (supervised), and the H29/H31 console tails.

---

## 2026-06-14 → 06-15 — UniFi Protect webhooks → HA, + HA automation behavior

**Goal:** Protect camera motion → HA light automations had stopped working
("webhooks not received by HA").

**Diagnosis journey (don't re-walk this):**
- Initial (pre-compaction) diagnosis blamed split-horizon DNS on the **UDM gateway**
  (`10.10.200.1`) resolving `ha.wind.etherport.net` to the Cloudflare edge → CF Access
  302. **That was the wrong host.** Protect runs on the **UNVR `Windprotect`
  (`10.10.212.10`)**, which uses Technitium and resolves `ha.wind` → `10.10.201.70`
  correctly (A + NODATA AAAA). A webhook POST from there returns HTTP 200. So DNS/
  network/HA were never the problem.
- A UDM Local DNS record was briefly added then **reverted** (owner: keep everything
  on Technitium for consistency — the UDM forwarding externally is by design).
- **Real root cause:** UniFi Protect's Alarm Manager webhook client has a bug — it
  feeds a multi-address `dns.lookup()` result into Node's single-IP connect path, so
  `net.isIP([ [Object] ])` throws **`ERR_INVALID_IP_ADDRESS`** and the request dies
  before any TCP connection. This breaks **every hostname-based webhook** (confirmed
  in `/srv/unifi-protect/logs/automationManager.log`: zero successful httpActions).
  Protect also **validates TLS**, so `https://10.10.201.70/...` (IP) fails
  `ERR_TLS_CERT_ALTNAME_INVALID`. Only an **IP-literal + plain-HTTP** URL works.

**Fix (shipped, commits `9fd7c50` + `840f6c0`):** a dedicated plain-HTTP Traefik
entrypoint `webhook` (`:8088`, no 80→443 redirect, no TLS) on the VIP, serving **only**
`PathPrefix(/api/webhook/)` → HA `:8123`. Files: `clusters/wind/helm-releases/traefik.yaml`
(the `webhook` port) + `platform/kubernetes/home-automation/ingressroute-webhook.yaml`.
Protect webhooks now use `http://10.10.201.70:8088/api/webhook/<id>`. Verified all 5
IDs return 200 from Protect; non-webhook paths 404 (least-exposure). Traefik rolled
zero-downtime (2 replicas, `maxUnavailable: 0`, PDB).

**Decisions / rejected options:**
- Rejected: HA macvlan IP (`10.10.202.25`) direct — firewalled from the camera VLAN.
- Rejected: source-lock the `:8088` route to Protect's IP via Traefik `ipAllowList` —
  the shared Traefik LB is `externalTrafficPolicy: Cluster` so kube-proxy SNATs the
  client IP and the allowlist 403s everything. Keeping it would need `Local` (cluster-
  wide ingress change) or a UDM firewall rule. **Owner declined** — the path is
  plain-HTTP, LAN-only, `/api/webhook/`-only, gated by 24-char secret IDs; marginal.
- The `protect-tf` 1P key authenticates the Protect **integration** API but that API
  is read-only for automations (no Alarm Manager endpoint), and the internal app API
  rejects it (401). So **the Alarm Manager URL edits can't be done via any API** —
  they're a Protect-UI task.

**HA automation behavior change (same session):** owner wanted re-triggered motion to
**reset** the off-timer (was ignored mid-run). Changed all 5 motion-light automations
from `mode: single` → **`mode: restart`** directly in `/config/automations.yaml`
(backup at `/config/automations.yaml.bak-premode-20260615-064254` in-pod; activated via
HA "Reload Automations"). Also clarified: editing/saving an automation mid-run cancels
the in-flight run (so a pending `turn_off` is abandoned → light stays on). `light.deck`
is a Hue light (healthy); the 03:40 deck-light-on event was *my* verification curl, not
real motion.

**State at end:** webhook path live + verified; automations on `restart`. Lights all
off. UDM DNS reverted. `protect-tf` temp key wiped from `/tmp`.

**Open / next steps:**
- ⏳ **Confirm all 5 Protect Alarm Manager URLs are switched** to
  `http://10.10.201.70:8088/api/webhook/<id>` (owner did some via UI; verify none still
  on `https://`/hostname or the old `https://10.10.202.25/...-bY8...`). UI-only.
- ⏳ (optional) add `protect-tf` to the SOPS bundle for headless Protect integration-API
  reads (camera/motion state for HA) — not needed for this fix.
- ⏳ (optional, declined) firewall source-lock for `:8088` — revisit only if desired.
- Relates to tracker **M48/M49/M50** (Protect IaC): webhook *routing* is now IaC;
  Alarm Manager automations remain UI-managed (no write API).

## Before 2026-06-14

See [`outstanding-work.md`](outstanding-work.md) "Recently completed" blocks and the
dated planning docs. Headline recent landings: H29 (CI→AWS OIDC), L21 (CI→GCP WIF),
M69 (Cloudflare provider v4→v5), M53 (zone-scoped CF token), the localtuya migration
(all 8 Tuya devices cloud→local, entity_ids preserved), and the headless Mac-mini ops
host. Older history archived under `archive/`.
