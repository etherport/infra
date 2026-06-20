# Outstanding Work — Consolidated Priority List

Latest revision: 2026-06-15 (Protect webhook fix + agent handoff system; prior
full-repo review 2026-06-10). Canonical filename `outstanding-work.md` is stable;
older dated snapshots live in `archive/`. Per-session narrative: `session-log.md`.

Successor to `archive/outstanding-work-2026-05-16.md`. Resets the priority lattice
after a multi-day session covering SDN migration, Ceph VLAN move, post-
migration cleanup, and IaC durability hardening.

**How to read this:** Items keep their original ID (`C1`, `H3`, …) across
revisions so history is grep-able. New items added since the prior
revision use the next free ID per tier. Status legend:

| Glyph | Meaning |
|---|---|
| ✅ | Done — landed in main, applied where applicable |
| 🟡 | In progress — partially landed or actively being worked |
| ⏳ | Pending — scheduled or queued |
| 📋 | Drafted — code/playbook ready, awaiting human-supervised apply |

---

## Next-up checklist (updated 2026-05-29)

Active execution order. The zone migration + switch ACLs + Kopia decom +
personal-web CI all landed this session (see "Recently completed" below).

| # | Item | State | Action |
|---|---|---|---|
| 1 | **M18/M36 MetalLB BGP** ✅ **DONE + VERIFIED 2026-06-12** | Was: MetalLB L2 mode → UDM `.5`/`.71` IP-conflict alerts | **A** 209 NICs → **B** 201→UDM-routed → **C** UDM↔MetalLB eBGP (8/8 sessions, 5 VIP /32s via BGP/ECMP) → **D** L2Advertisement removed (`69a332b`) = **BGP-only**. VIPs verified reachable intra-201 (kube-proxy) + cross-VLAN (BGP); only raw ICMP-to-VIP stops (harmless). M36 root cause (ARP/MAC churn) gone. ✅ **Verified 2026-06-12 via Loki** (`{host="udm"}`, 14d incl. ~2d pre-fix overlap back to 05-29): **0** `.5`/`.71` conflict/duplicate alerts. Closed. Runbooks: bgp-phase-{a,b,c}. UDM BGP is UI-managed (no API) — durable via git FRR config + controller backup; recheck → M58. Trusted-zone for 201 → M56. |
| 2 | **M15-M17 Twilio Talk** | 911 addr / orphan DID / SIP UDP→TLS+sRTP | M15 (911) safety-first; M16 release DID; M17 encryption |
| 3 | **M53 CF token scoping** ✅ **DONE 2026-06-13 (personal-web)** | Was: account-scoped token shared infra↔personal-web | personal-web CI now uses a **zone-scoped** token (`cloudflare-personal-web-tf`: grahamsmith.net/smithforsb.com/stopthecastle.com only, + DNSSEC + Dynamic Redirect) — GH secret updated, verified `cloudflare-dns` plan clean. It can no longer reach etherport. **Remaining (optional):** re-scope the *infra* token to etherport-only (needs a `sync-secrets.py` re-bake of the mini's SOPS bundle). Headless CF for the personal-web agent: local-only `secrets/cloudflare.sops.yaml` on the mini (gitignored per personal-web convention; holds the **master** token — owner-okayed — so the agent can run CF terraform/M54 without op/1P). |
| 4 | **M54 smithforsb redirect IaC** 🟢 **UNBLOCKED** | CF Single Redirect still manual in dashboard | M53's scoped token has `Dynamic Redirect: Edit` → personal-web agent can now codify it (`cloudflare_ruleset` in `cloudflare-dns/smithforsb.tf`, import the live rule, verify 301). |
| 5 | **M48/M49/M50 UNAS+Protect IaC** | UI-only | Per-device API keys → Ansible playbooks + coverage audit |
| 6 | **M69 Cloudflare provider v4→v5** ✅ **APPLIED + VERIFIED 2026-06-13** | Was: 51 resources incl. Tunnel + Zero Trust Access (breaking rewrite) | Migrated live (headless via SOPS token): `39 imported, 11 benign in-place, 0 destroyed`; post-apply plan = **No changes**. cloudflared 0 restarts; Access gating intact (approve/grafana/wiki 302 externally). PR **#66** reconciles `main`→v5. personal-web migrated first as proving ground. Plan/log: [`cloudflare-provider-v5-migration.md`](cloudflare-provider-v5-migration.md). |
| 7 | **L21 GCP auth → WIF** ✅ **DONE 2026-06-13** | Was: `terraform-google` red since inception (empty `GCP_SA_KEY`, never applied) | GitHub→GCP **Workload Identity Federation** live — no static key (mirrors H29). WIF pool/provider/SA `gh-actions-terraform` bootstrapped in `homelab-infra-497414`; workflow on `google-github-actions/auth@v2`; both projects imported; CI dispatch = **"No changes"**. Enabled `iamcredentials`/`cloudresourcemanager`/`cloudbilling` APIs + declared `billing_account` on the CF-SSO project to kill import drift. `terraform-google` now green. Doc: [`gcp-oidc-wif-l21.md`](gcp-oidc-wif-l21.md). |

**Recently completed (this session, 2026-05-27 → 29):**
- ✅ BGP **Phase A** — 209 (vsan) NIC added to w1-4 + gpu1 (DHCP .100-.104); kubelet NFS to the UNAS now egresses `enp6s23` at L2. Caught + fixed the source-IP gap: UNAS NFS export ACL extended to the 209 IPs on all 9 shares (UI, not IaC — re-apply on rebuild). Runbook updated with the "additive path ≠ no behaviour change" lesson.
- ✅ Velero `kube-system-daily` PartiallyFailed (recurring ≥4d) root-caused — node-agent lacked control-plane tolerations so it skipped cilium's `tmp` fs-backup on cp1-3. Fix: `nodeAgent.tolerations` in velero values (Flux). No data loss (resource backup was 371/371; only an ephemeral emptyDir was un-backed-up).
- ✅ M32 firmware channel → `release` + M34 site-wide auto-upgrade → off (IaC: `udm-firmware-policy.yml`, commit `ea08bea`)
- ✅ M30 — UDM zone migration COMPLETE (IoT + Infrastructure/212 + Security/205 custom zones; Phase 4 skipped)
- ✅ M52 — L3-switch ACL IaC applied + verified (5 ACLs on Switch Rack PoE)
- ✅ M33 rsyslog → Loki; M31 backup + OOB verified; 14 firewall groups (`3271cea`)
- ✅ Kopia decommissioned (deployment + CF tunnel + monitoring + 205 GiB Ceph reclaimed)
- ✅ personal-web repo CI (GH Actions + secrets; all 3 modules plan clean)
- ✅ CF API token fixed (user-rotated) + etherport DS record re-imported + `ignore_changes` pinned
- ✅ M30 Phase 1: VLAN 212 → Infrastructure zone (commit set through `05d635c`); all 18 clients healthy
- ✅ M30 §7 questions resolved + L3-routing topology corrected (Switch Rack PoE routes 201/202/209/210)

**Recently completed (2026-05-30 → 31):**
- ✅ BGP migration **A→D COMPLETE** — node 209 NICs, 201→UDM-routed, UDM↔MetalLB eBGP, L2Advertisement removed. M18/M36 resolved.
- ✅ vpn-local wg-failover self-heal (`reset-failed`); advisor vpn-local SSH-IP fix (.5→.15); sops+age in the CI runner (SOPS playbooks now run in CI).
- ✅ cw2loki "unknown" report bug fixed (cronjob `time()` scalar parse); appliance probes (UDM/Protect/UNAS) scraping; Velero node-agent on all 8 nodes.
- ✅ Networking prod-review (`networking-prod-review-2026-05-31.md`): P1.2 default-deny verified, P1.3 DDNS confirmed working, NetFlow decided (superseded by unifi-poller).
- ✅ Doc consolidation: archived 21 done/superseded docs; this tracker trimmed 684→~270 lines (full snapshot in `archive/outstanding-work-snapshot-2026-05-31.md`).

**Recently completed (2026-06-01 → 10):**
- ✅ **Headless ops host** — always-on Mac mini (`10.10.202.101`, tailnet `100.79.165.113`) provisioned as the Claude Code Remote Control box: full kubectl/terraform/sops/ansible with **no 1Password at runtime** (commits `00f365f`, `14e1f07`). AWS creds baked into SOPS (`scripts/render-aws-credentials.sh`); proxmox tf creds via `scripts/tf-proxmox.sh`; scoped `trusted-admin-clients → Management` UDM rule (applied from the mini). Procedure: `docs/setup/headless-ops-host.md`.
- ✅ Doc accuracy pass (2026-06-10): README (headless host, M56 zone split, MetalLB BGP-not-L2) + `firewall-zones.md` (the new trusted-admin-clients rule) updated.

**Recently completed (2026-06-13 → 15):**
- ✅ **M69 / L21 / M53** — Cloudflare provider v4→v5 (PR #66), CI→GCP WIF, zone-scoped CF token (details in their tier entries + planning docs).
- ✅ **localtuya migration** — all 8 Tuya devices moved cloud→local (localtuya), entity_ids/names/automations preserved; trial-expiry-proof. (HA-side, not in repo IaC.)
- ✅ **Protect webhooks → HA fixed** (commits `9fd7c50`, `840f6c0`). Root cause was a Protect Alarm Manager bug (`ERR_INVALID_IP_ADDRESS` on hostname webhooks), NOT DNS/network. Added a dedicated plain-HTTP Traefik `webhook` entrypoint (`:8088`, `PathPrefix(/api/webhook/)` → HA:8123); Protect uses `http://10.10.201.70:8088/api/webhook/<id>`. Full narrative in [`session-log.md`](session-log.md).
- ✅ **HA motion-light automations → `mode: restart`** so re-triggered motion resets the off-timer (was `single`).
- ✅ **Agent handoff system** — added root `CLAUDE.md` (entry point + operating model + maintenance rules) + this file's companion [`session-log.md`](session-log.md) (narrative journal).

---

> 🗺️ **Forward-looking dev roadmap** (reliability · security maturity · platform/capabilities ·
> devex/automation/cost) lives in [`dev-roadmap-2026-06-11.md`](dev-roadmap-2026-06-11.md).

## Full-repo review — 2026-06-10

A 5-dimension review (IaC consistency · k8s/Flux · docs · security-hardening ·
CI/supply-chain) ran 2026-06-10. New items carry IDs **H29–H34 / M60–M68 /
L16–L20**. Headline corrections + top gaps:

- ⚠️ **H3 was overstated** — the "audit-only CNPs already deployed" claim is
  FALSE. There are **zero** NetworkPolicy/CiliumNetworkPolicy objects in the repo
  and Cilium `policyEnforcementMode` is unset (allow-all). H3 reframed below.
- **Top hardening gaps (new):** 22 CI workflows on long-lived static AWS keys, 0
  OIDC (**H29**); 0 SHA-pinned actions / 0 digest-pinned images (**H30**);
  orphaned `claude-admin-temp` IAM policy with `iam:*`/`DeleteUser` on `*`
  (**H31**); auto-remediation SA has cluster-wide `delete pods/PVCs` (**H32**); no
  secrets-rotation runbook + single age key (**H33**).
- **What's genuinely solid** (don't re-spend): no plaintext secrets in tree/history;
  SOPS pre-commit gate works; `kube_encrypt_secret_data: true`; EBS encryption;
  minimal regex-scoped public tunnel surface; cloudflared pod well-hardened;
  broad+alerted backups; resource-prefixed `terraform-*` IAM policies.

📋 **Detailed, ready-to-execute implementation plans for H3 + H29–H34** (steps,
exact commands, sequencing, verification, rollback) live in
[`hardening-plan-2026-06-10.md`](hardening-plan-2026-06-10.md). Recommended order:
H34 → H31 → H29 → H30 → H33 → H32 → H3.

---

## Open items

_Completed items (C1–C3, H1–H28, and the many done M-items) moved to the full snapshot: `archive/outstanding-work-snapshot-2026-05-31.md` (grep there for history). This file now lists only open/in-progress/gated work._

## HIGH — production-readiness; 1–2 weeks

### 🟡 H3. NetworkPolicies — Phase-1 manifests authored (inert) 2026-06-15
- **Source:** `archive/outstanding-work-2026-05-16.md` H3; task #2.
- **Reality check (2026-06-10):** despite prior notes, `platform/kubernetes/policy-baseline/` contains ONLY LimitRanges + ResourceQuotas. There are **zero** NetworkPolicy / CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy objects anywhere, and Cilium is allow-all. So every pod can reach every other pod + external — a compromised workload (public-facing cue-api, plex) has unrestricted lateral movement. The "audit-only CNPs already deployed" claim was wrong.
- ✅ **Phase-1 authored 2026-06-15** (`platform/kubernetes/networkpolicies/`, **NOT yet wired into Flux** — inert): default-deny CCNP + universal allows (DNS via host/remote-node:53 for the link-local nodelocaldns `169.254.25.10`, kube-apiserver, host/probe, monitoring scrape) + the first concrete tier (`postgres-ingress`: only cnpg-system + wikijs reach :5432, monitoring :9187). Phasing = per-namespace opt-in via the `netpol.wind/enforced=true` label. All 5 validate server-side against the live Cilium 1.18.6 CRDs. README documents the rollout/rollback.
- ⚠️ **Findings that change the plan:** (a) **audit mode is OFF** — must be ON before anything applies or it's an instant outage (Cilium: any directional rule on a pod → default-deny that direction). (b) **Cilium is Helm-managed** (release `cilium`/kube-system), NOT Flux.
- 🛑 **Audit-mode-via-kubespray attempt caused a contained Cilium incident 2026-06-15 (recovered).** `cluster.yml --tags=cilium` chowns `/opt/cni/bin` to `kube_owner` (kube) → Cilium `mount-cgroup` (root, `drop:[ALL]`) can't write → `Init:CrashLoopBackOff` on agent restart. Recovered by `chown root:root /opt/cni/bin` (the existing `pre-flight.yml` enforces this; cluster.yml had undone it). Full write-up: [`session-log.md`](session-log.md) + [`../runbooks/cilium-cni-dir-owner.md`](../runbooks/cilium-cni-dir-owner.md). CLAUDE.md §5 updated.
- ✅ **Audit mode ENABLED + IaC-durable 2026-06-15.** Live via `kubectl patch cm cilium-config policy-audit-mode=true` + `rollout restart ds/cilium` (clean roll, dir is root-owned); **runtime `PolicyAuditMode: Enabled` on all 8 agents**. Durability: `cilium_policy_audit_mode: true` committed to kubespray inventory (survives a kubespray render) + `kubespray.sh` wrapper now auto-runs `pre-flight.yml` post-cluster.yml (restores `/opt/cni/bin` root owner) + `cilium_extra_values` DAC_OVERRIDE backstop. `kube_owner: root` rejected (system paths genuinely kube-owned).
- ✅ **Wired into Flux + observation STARTED 2026-06-15** (commits `4005fed`/`00bdb81`): `platform/kubernetes/networkpolicies/` in `clusters/wind`; 3 allow CCNPs + `postgres-ingress` `VALID: True` (the standalone default-deny CCNP was dropped — Cilium rejects empty-rule policies; the allow-* policies' selection provides the implicit default-deny). **`postgres` labeled `netpol.wind/enforced=true`** → endpoint verified `Disabled (Audit)` both directions.
- ✅ **Observation moved into Loki/alerts 2026-06-18** (`c269ebb`, replaces the interactive `audit-report.py` `/loop`): Cilium now exports `verdict=AUDIT` flows → a per-node file → **Alloy** → Loki `{job="hubble-audit"}` → **loki-ruler** `CiliumNetpolAuditFlow` alert (excludes already-triaged postgres-replication + cnpg-system, so only NEW tuples page) → Alertmanager/advisor. Continuous, low-noise, queryable in Grafana — no chat loop. Durable via `cilium_config_extra_vars` in the kubespray inventory. See session-log 2026-06-18. `scripts/cilium/audit-report.py` stays as an ad-hoc one-shot.
- **Next (multi-week observation):** triage `CiliumNetpolAuditFlow` alerts + the Grafana `{job="hubble-audit"}` view (cover CNPG backup/cron paths) → refine the postgres allowlist (allowlisted flows stop AUDITing automatically) → label the next tier (cue→dns→traefik→monitoring), one `1x-tier-*` allowlist per tier from audit data → when all target namespaces' allowlists are verified, disable global `policy-audit-mode` to enforce + retire the export keys. Exclude wireguard/kube-system/flux-system.
- **Effort:** L (phased over ~2 weeks of observation). **Largest internal-segmentation gap.**

### ✅ H35. Cilium/kubespray durability hardening (post-incident) — DONE 2026-06-15
- **Source:** 2026-06-15 Cilium incident.
- ✅ **(b) kubespray.sh wrapper rewritten** — correct paths (`~/.kubespray-venv`, `inventory/inventory.ini`, ssh user/key) + **auto-runs `pre-flight.yml` after cluster.yml/upgrade-cluster.yml/scale.yml** so `/opt/cni/bin` root ownership is restored every run.
- ✅ **(c) `cilium_extra_values` DAC_OVERRIDE backstop committed + validated by analysis** — kubespray passes it as the **last `-f`** to `cilium upgrade` (`roles/network_plugin/cilium/tasks/apply.yml`); the base `values.yaml.j2` doesn't set `mountCgroup`; the path matches the live chart default → the override renders on the next kubespray run. Full *functional* confirmation (DAC_OVERRIDE alone vs other init containers) comes naturally on the next real kubespray run; the wrapper's auto-pre-flight is the primary fix regardless.
- ✅ **(a) Helm release cleaned** — `helm rollback cilium 14` → clean `deployed` rev 16, superseding `failed` rev 15. Audit still Enabled on all 8 agents.
- ✅ **(d) `setup.sh` rewritten** — creates `~/.kubespray-venv` (matches the wrapper), drops the stale inventory symlink, points at `kubespray.sh` + the runbook.
- **Residual:** the next real kubespray run is the live DAC_OVERRIDE functional test (watch Cilium agents come up healthy).

### ✅ H29. CI AWS auth → GitHub OIDC — CUTOVER COMPLETE 2026-06-12
- **Source:** review 2026-06-10. 22 workflows inject `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (GH secrets); **0** use OIDC (`role-to-assume`/`id-token: write` absent). Long-lived IAM keys in CI = classic exfil target, no expiry, manual rotation across many secrets.
- **Fix:** IAM OIDC provider for `token.actions.githubusercontent.com` + `gh-actions-terraform` role (trust scoped to `repo:sparked-diamond/infra:ref:refs/heads/main`); add `permissions: id-token: write` + `aws-actions/configure-aws-credentials` `role-to-assume`; delete static keys. Free, mechanical — **highest-ROI hardening**.
- 🟡 **Stack authored 2026-06-12** (`infra/terraform/aws/github-oidc/`): OIDC provider + `gh-actions-terraform` role (trust = repo main+PR) + `PowerUserAccess` + scoped `gh-actions-terraform-iam` (anti-escalation Deny). `terraform validate` passes. **Bootstrap needs a one-time ADMIN apply** (claude-admin is PowerUser/no iam:* — use a temp `gs_admin` key; see the stack README), then cutover the 22 workflows. NOT yet applied.
- ✅ **Bootstrap applied** (gs_admin one-time, 2026-06-12) + **all 22 AWS-using workflows migrated** to the `gh-actions-terraform` OIDC role (13 github-hosted + 5 self-hosted action-input + 4 self-hosted job-env). Verified green: 13 github-hosted plans, cloudflare (self-hosted action-input), unifi (self-hosted job-env). `grep secrets.AWS_ACCESS_KEY_ID .github/workflows` = 0.
- ✅ **Final step — resolved 2026-06-17:** the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` GH secrets are **already removed** (verified: `gh secret list` has no `AWS_*`; 0 workflows reference static keys). The CI-exfil risk is fully neutralized — CI is OIDC-only. **The `terraform-homelab` access key is INTENTIONALLY RETAINED, not deleted:** it has exactly one key (`AKIA…JHIX`), Active + used daily by the **mini's local `homelab` profile** for headless terraform/AWS (the shared-key dependency in CLAUDE.md §4). Deleting it would break all headless ops. So the original "delete the key" step is **superseded** — the threat it addressed (long-lived key *in CI*) is gone; the key now serves local ops only (accepted risk). A future cleanup *could* mint a separate dedicated key/user for the mini and then retire this one, but that's net-new work, not part of H29. **Note:** `terraform-google` previously failed on an empty `GCP_SA_KEY` — fixed by L21 (WIF).
- ✅ **Extended to personal-web 2026-06-12** — added a second role `gh-actions-personal-web` to the same `github-oidc` stack (trust = `repo:sparked-diamond/personal-web` main+PR; `PowerUserAccess` + scoped `gh-actions-personal-web-iam` limited to `role/ses_put_s3_role` + anti-escalation Deny). Applied via gs_admin (`6dc79ea`, ARN `…:role/gh-actions-personal-web`). **Workflow flip + static-key-secret deletion happen in the personal-web repo** (handed to that thread) — removes personal-web as a consumer of the shared homelab static key.

### 🟡 H30. Supply chain — SHA-pin Actions + digest-pin images
- **Source:** review 2026-06-10. **0** of 104 `uses:` were SHA-pinned; **0** of 22 image refs `@sha256`-pinned; in-house images pull `:main`; SOPS binary curl'd unverified in 3 workflows.
- ✅ **Done 2026-06-11 (safe/non-rolling):** added `helpers:pinGitHubActionDigests` to `renovate.json` (next Renovate run opens a reviewable PR SHA-pinning all actions); authored `.github/actions/setup-sops/action.yml` (pinned + **checksum-verified** SOPS install, sha256 `5488e32b…` from the official checksums).
- ✅ **Actions SHA-pinned 2026-06-13:** Renovate PR **#62** ("pin dependencies") merged — **all 111 `uses:` now digest-pinned** (was 0). (The pin PR was unblocked by raising `prConcurrentLimit` 5→8, and went green once L21's WIF fixed `terraform-google`.)
- ⏳ **Deferred to supervised (rolls pods / can break CI):** wire the 3 workflows (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn`) to `setup-sops`; add `digestReflectionPolicy: Always` to the 8 Flux `ImagePolicy` objects (image-reflector is v1.0.4 — supports it; triggers manifest-rewrite + pod rolls); bring in-house images under Flux + re-enable their Renovate digest tracking.
- 🟢 **`cue-api` `:latest` — intentional during dev (owner 2026-06-17):** the dangling `$imagepolicy` marker on cue-api (no matching ImagePolicy → floats on `:latest`) is **accepted for now** — cue is in active development / testing mode, so always pulling latest is desired. **Do not pin/fix this yet.** Revisit when cue-api goes to production (then either add a real `cue-api` ImagePolicy or pin by digest, and remove/repair the marker). Tracked here so the supply-chain sweep doesn't "fix" it prematurely.
- **Effort:** M remaining.

### ✅ H31. Redesign `claude-admin` (break-glass, broad-but-not-escalation) + full IAM audit — APPLIED 2026-06-11
- **Reframe (owner 2026-06-11):** keep `claude-admin` as a deliberate one-off/break-glass user **outside Terraform**, but **broad-but-safe**. Chosen design: `PowerUserAccess` (all services except IAM/Org) + `claude-admin-oneoff-roles` (create/manage IAM roles under the `claude-*` prefix, **boundary-delegated** so no role it makes can do IAM writes → no escalation) + the scoped `claude-admin-policy`.
- ✅ **IaC done 2026-06-11:** deleted `claude-admin-temp.json` (the `iam:*`/`DeleteUser`/`s3:DeleteBucket`-on-`*` escalation primitive — confirmed still attached live); scoped `claude-admin-policy.json` (`IAMOrphanCleanup` → `user/terraform-*`; dropped `secretsmanager` write on `*`); added `claude-oneoff-boundary.json` (PowerUser ceiling) + `claude-admin-oneoff-roles.json` (boundary-gated role mgmt). Full user audit (10 users) captured in the review doc.
- ✅ **APPLIED 2026-06-11** (VNC bundle as claude-admin): created `claude-oneoff-boundary` + `claude-admin-oneoff-roles`; attached `PowerUserAccess` + `claude-admin-oneoff-roles`; pushed scoped `claude-admin-policy` (v9); **detached `claude-admin-temp`**. Verified: attachments = policy + oneoff-roles + PowerUserAccess (no temp); de-escalation confirmed (claude-admin lost the broad `iam:GetPolicy`-on-`*` that only temp granted).
- ✅ **Manual nit cleared — verified 2026-06-17:** the `claude-admin-temp` policy object **no longer exists** (`aws iam get-policy` → `NoSuchEntity`; not in `list-policies --scope Local`). Already deleted. The only `claude-*` customer-managed policies remaining are the intended design: `claude-admin-policy` (attached), `claude-admin-oneoff-roles` (attached), `claude-oneoff-boundary` (0 attachments — correct, it's a permissions-boundary referent, not an attachment). H31 fully closed.
- ⏳ **Audit follow-ups (from the 10-user sweep):** `kubernetes-s3-backup` has an odd inline `billing-access`; `terraform-homelab` has redundant direct+group grants (H29's OIDC role consolidates). Details in `aws-iam-review-2026-06-11.md`.

### ✅ H32. Scope auto-remediation RBAC — confined destructive verbs (2026-06-11)
- **Source:** review 2026-06-10. `platform/kubernetes/auto-remediation/rbac.yaml` grants the controller SA cluster-wide `pods: delete`, `pvc: patch,delete`, `cnpg clusters: patch,update`. The "never auto CNPG/Ceph/kube-system" rule is code/prompt-only (`AI_NAMESPACE_DENYLIST`), not RBAC.
- ✅ **Done 2026-06-11:** moved the irreversible verbs (`pvc:delete`, `cnpg:patch/update`, `velero:create`) out of the cluster-wide ClusterRole into per-namespace Roles (`postgres` + `velero`) in a NEW `platform/kubernetes/auto-remediation-rbac/` dir (no namespace transformer, so the Roles land correctly — the original `auto-remediation/` kustomization's `namespace:` transformer would have relocated them). Recoverable verbs (pod restart, scale, job cleanup, pvc *expand*) stay cluster-wide. **Verified before push:** new dir renders Roles in postgres/velero, full `kubectl kustomize clusters/wind` builds clean (382 resources, no Flux-freeze), ClusterRole now `pvc: get/list/patch` only. Closes "delete any PVC in any namespace" (incl. cnpg-system/rook-ceph).
- ⏳ **Remaining (optional, supervised):** full hard-denylist via a per-namespace allowlist for ALL mutating verbs (this change confined only the *irreversible* ones; pod-restart etc. stay cluster-wide).

### ✅ H33. Secrets-rotation runbook + 2nd age recipient (single-key blast radius) — DONE 2026-06-15
- **Source:** review 2026-06-10. One age recipient decrypts ALL secrets; the private half is replicated to **3 holders** (mini disk, GH `SOPS_AGE_KEY`, Flux `sops-age`) — that's the real blast radius. No re-key path existed.
- ✅ **Done 2026-06-11:** wrote `docs/runbooks/secrets-rotation.md` (blast-radius inventory, routine two-phase rotation, full "mini compromised → rotate everything" incident procedure incl. the 1P-managed vs hand-edited secret split).
- ✅ **H33a done 2026-06-15:** added the offline backup age recipient `age1phcm…3466` ("Homelab SOPS Age Key (BACKUP)", offline only — never on mini/CI/Flux) to all 15 `.sops.yaml` (5 root rules + 14 nested) + `sops updatekeys` across all **39** secret files. Verified: every file carries both recipients; all 39 decrypt with the primary; the live system reconciled clean. Keypair generated on the laptop (private half offline only). The primary stayed a recipient throughout → no Flux/CI/GH-secret change, zero lockout window. (Renamed the existing 1P primary item → "Homelab SOPS Age Key (PRIMARY)".)
- ✅ **(b) FileVault** confirmed already enabled on the mini (owner, 2026-06-15).
- ⏳ **(c) optional per-domain recipient split** — deferred (nice-to-have; not blocking). H33 core is **done**.
- **Effort:** none required; (c) optional.

### ✅ H34. Narrow + log the `trusted-admin-clients → Management` firewall rule (2026-06-11)
- **Done:** rule narrowed from `protocol: all` → entire Management zone, to `protocol: tcp` + `Mgmt-Admin-Ports` (22/443/8006) + `mgmt-admin-hosts` address-group (PVE `10.10.200.41`), `logging: true`. Applied from the mini; old broad `(all)` policy deleted via API (the playbook is create-only, so narrowing = create-new + delete-old). **Verified:** admin ports 22/8006 connect, non-admin 8007/3128 time out (dropped). (ICMP to mgmt hosts still passes — a UniFi default, not this rule.)
- **Remaining nicety:** add switch mgmt-UI IPs to `mgmt-admin-hosts` if/when needed.

### ✅ H36. Flux reconciliation alerting (silent GitOps-wedge gap) — DONE 2026-06-17
- **Source:** 2026-06-17 — a CNPG webhook cert inconsistency wedged the flux-system Kustomization for ~hours, blocking ALL GitOps, found only by luck (mid-M62). Flux metrics weren't scraped → failures invisible.
- ✅ **Done 2026-06-17** (`platform/kubernetes/monitoring/07-flux-monitoring.yaml`): **PodMonitor** for the flux controllers (`app.kubernetes.io/part-of: flux`, port `http-prom`/8080, `honorLabels`) — verified all 6 controllers scraping `up`. **`PrometheusRule` FluxReconciliationErrors** alerts on `sum by(app,controller) rate(controller_runtime_reconcile_total{namespace="flux-system",result="error"}[5m]) > 0 for 15m`. **Note:** this flux build does NOT export `gotk_reconcile_condition` (only `gotk_reconcile_duration_seconds` + `controller_runtime_*`), so the alert keys off sustained reconcile errors instead — a wedged Kustomization/HelmRelease errors continuously, so it fires within 15m. Rule loaded + evaluating (0 firing = healthy).
- **Related (smaller):** evaluate switching CNPG webhook certs to **cert-manager + ca-injector** (`caBundle` auto-injected/maintained → no operator-managed-cert drift like the 06-17 incident). The operator self-managing certs is the default + worked again after a restart; cert-manager would make it self-healing. Deferred — bigger change for a one-time glitch.

### ✅ H37. Proxmox host firewall (host mgmt plane) — ENFORCING (default-deny) 2026-06-17
- **Source:** zero-trust assessment 2026-06-17 (owner-requested). The hypervisor is the crown jewel but its **PVE firewall is not in IaC and effectively permissive**. Scope narrowed to the **host management plane** (k8s-node + standalone-VM firewalling split to **M77**). Full spec: [`zero-trust-assessment-2026-06-17.md`](zero-trust-assessment-2026-06-17.md).
- ✅ **Investigated 2026-06-17:** PVE firewall is entirely OFF (datacenter/node/all guests; 0 rules/ipsets). Node = `pve` (10.10.200.41), 13 running guests. **All VM NICs are `firewall=0`** → enabling the host firewall does NOT cascade onto guests (key safety fact). Admin-access SNAT ambiguity (TS subnet-router / WG-pod MASQUERADE / mini-LAN) is why the rollout is **staged: permissive+log → observe → enforce**.
- ✅ **Stage-1 authored** (`infra/terraform/proxmox/firewall/`, new stack): cluster firewall **enabled, input_policy=ACCEPT (permissive)**, output/forward ACCEPT; node `pve` firewall enabled with `log_level_in=info`; IPset `mgmt-admin` (10.10.200/201/202 + 100.64/10 tailnet + WG 10.254/24 + 10.255.255/29); security group `pve-mgmt` (ACCEPT 22/3128/8006 + Ping from mgmt-admin); attached to the node. `terraform plan` = **5 add, 0 change, 0 destroy**, validates clean.
- ✅ **Privilege unblocked + Stage 1 APPLIED 2026-06-17:** owner granted `Sys.Modify` on `/` (custom `TerraformFirewall` role on the `graham@pam!terraform` token). `terraform apply` created all 5 resources. **Verified LIVE:** datacenter firewall `enable=1, policy_in=ACCEPT` (permissive), node `pve` `enable=1, log_level_in=info`; `mgmt-admin` IPset (6 CIDRs) + `pve-mgmt` SG attached. **No lock-out** (API responds through the firewall), **all 13 guests still running**. Also set the `pve-mgmt` allow rule `log=info` for the observation window (positive confirmation of admin matches; revert to `nolog` at Stage 2).
- 🔭 **NOW: observation window.** Watch `/nodes/pve/firewall/log` to confirm every legit admin path (PVE UI/SSH from **laptop on TS**, **laptop on WG**, **mini**) shows as a `mgmt-admin` ACCEPT match — i.e., its (possibly SNAT'd) source falls in 200/201/202/tailnet/WG — and that nothing legit appears in the would-be-dropped (default-policy) log. Exercise each path so it logs.
- ✅ **Observation verified + back-door fixed (2026-06-17):** firewall log over the window showed all admin sources hitting 22/8006 are inside `mgmt-admin` — mini (`10.10.202.101`), TS/WG via 201 (`10.10.201.55/.56`), and the **UDM backup WG** (`192.168.3.2`) — and **0 sources outside `mgmt-admin`** touched 22/8006/3128. Host only ever receives 22+8006 (no exporters to strand). The backup-WG door (host-independent break-glass) failed initially due to a **client-side DNS issue** (full-tunnel without internal DNS); owner fixed it + it now logs as `192.168.3.2`; added `192.168.3.0/24` to `mgmt-admin`. **IPMI/console break-glass confirmed.**
- ✅ **Stage 2 ENFORCED (2026-06-17):** flipped `local.input_policy` ACCEPT→DROP + rule `log`→`nolog`, applied. **Verified:** datacenter `enable=1, policy_in=DROP`; host reachable (mini API 3/3 HTTP 200, ports **22 + 8006 OPEN** from the mini through the enforcing firewall); **all 13 guests still running**. Owner separately confirming the VPN interfaces (TS/WG/backup-WG). Reversible: set `input_policy="ACCEPT"` + apply (mini is in `mgmt-admin`, so the control path survives; IPMI = hard backstop). **k8s-node + standalone-VM firewalling remains M77.**
- 🛑 **OVERSIGHT → fixed 2026-06-19: the DROP policy blocked all NEW K8s↔Ceph connections.** The host runs the **external Ceph mon+OSDs on `vmbr0.210` (10.10.210.41)** and the K8s nodes are RBD clients on the storage VLAN `10.10.210.0/24` — there was **no Ceph allow rule**. Existing RBD sessions survived via conntrack (latent), but the first *fresh* rbd map/create failed (`DeadlineExceeded`/`exit 108`) ~30h later — wedged technitium-1 + blocked dynamic provisioning; **cluster-wide latent risk** (any node reboot/reschedule/new PVC). **Fix (`d8fc8d4`/`982df07`):** added a **`pve-ceph` security group** (storage VLAN → `3300,6789,6800:7300`) + node attachment; `terraform apply` = `1 add, 1 change, 0 destroy`; **proven** (provision+map+mount work again). NB: `d8fc8d4` msg wrongly says a live `pvesh` hotfix was applied — it wasn't (classifier-blocked); **TF-only**. CLAUDE.md §5 gotcha added: *never tighten the host firewall without keeping the Ceph allow.* Applied from **devbox** (now TF-capable — see below). Full narrative: [`session-log.md`](session-log.md) 2026-06-19.

### ✅ H40. Technitium DNS replica made disposable (recreatable from code) — DONE 2026-06-19
- **Source:** owner directive 2026-06-19 ("make all services disposable / recreatable from code"), surfaced when technitium-1's RBD volume wedged (H37/Ceph incident above) and was re-provisioned onto a fresh PVC. A fresh replica didn't self-bootstrap — **(1)** `dns-sync` only *added* records, never created the `wind.etherport.net` zone; **(2)** it auths as the custom `graham` user, which doesn't exist on a fresh replica (only built-in `admin`, password from `DNS_SERVER_ADMIN_PASSWORD`).
- ✅ **Done (`500a250`/`982df07`):** `dns-sync` (`07-dns-sync.yaml`) now **creates the Primary zone if missing** + **tries `graham`, falls back to `admin`** to bootstrap a fresh server. **Verified:** re-provisioned technitium-1 → fresh PVC → self-bootstrapped (admin → zone-create → 45 records) → STS 2/2, both `.5` endpoints, `-1` answers `devbox.wind.etherport.net`. Old wedged image `csi-vol-ba25c344` retained in Ceph (Retain) for forensics — `rbd rm` when done. ✅ **Rotation-window hardening DONE (`4434719`, 2026-06-19):** readinessProbe now gates the `.5` rotation on **local zone presence** (`dig +norecurse SOA`) so a fresh replica stays out until dns-sync creates its zone (liveness stays HTTP so it isn't restart-looped); `technitium-headless` set `publishNotReadyAddresses: true` so dns-sync can still reach the not-ready replica to bootstrap it (no deadlock). Old wedged image `csi-vol-ba25c344` **deleted** from Ceph (`rbd rm`; root cause was the firewall, data was disposable). **Fully closed.**

### ⏳ M82. Decide: keep Terraform on devbox or re-home for ZT
- **Source:** 2026-06-19. To apply the H37/Ceph firewall fix from devbox (dev sessions moved off the mini — M81), devbox was made **TF-capable**: `terraform` 1.15.5 + `aws` CLI + the homelab AWS profile rendered from SOPS + PVE token via `scripts/tf-proxmox.sh`. This **expands devbox's blast radius** (now holds the homelab AWS keys + PVE token) — counter to the original "devbox = no TF/creds" design and the ZT direction ([[M71]]/[[H38]]). Owner accepts for now (it was needed). **Decide:** keep it (codify into `devbox.yml`), or re-home TF to the mini / a CI workflow (note: the proxmox-firewall stack has **no CI workflow** — adding one would let firewall changes apply via the self-hosted runner instead of any workstation). **Effort:** S (decision) + S–M (codify or build the workflow).

### 🟡 M83. GPU dcgm-exporter wedge → empty GPU dashboard (recurrable) — REMEDIATED 2026-06-19
- **Source:** owner 2026-06-19 ("GPU dashboard has no data"). `nvidia-dcgm-exporter` on `k8s-gpu1` was wedged — `/metrics` timing out (`TargetDown`), `nvidia-smi` itself hung (D-state) → **GPU driver/DCGM wedged at the kernel level** (flaky since ~06-10 per its logs). Pod restarts can't fix it (old container stuck Terminating, new one re-hangs on the wedged driver). **GPU compute (ollama/Plex) was unaffected** — monitoring only.
- ✅ **Remediated:** rebooted gpu1 (Proxmox **VM 120**) via `qm shutdown --timeout 60 --forceStop 1 && qm start` (graceful-then-force → clean Ceph unmount, no stale-EIO). Post-reboot verified: operator-validator 1/1, dcgm serves metrics, `DCGM_FI_DEV_GPU_UTIL` live in Prometheus (target `up`), ollama/plex back clean. Runbook: [`../runbooks/gpu-dcgm-exporter-wedge.md`](../runbooks/gpu-dcgm-exporter-wedge.md).
- 🟡 **Durability gap (can recur):** the gpu-operator `ClusterPolicy.dcgmExporter` exposes **no `livenessProbe`**, so self-restart-on-hang isn't configurable via IaC (and a probe can't kill a D-state container anyway). Mitigation = the **`TargetDown` alert → advisor** (early warning) + the runbook (fast reboot). **If recurring:** investigate the NVIDIA driver/DCGM version for a kernel-wedge bug (ClusterPolicy `driver`/`dcgmExporter.version`), or add a node-level watchdog (nvidia-smi-hang → auto-reboot). **Effort:** S done; driver investigation M (only if it recurs).

### ✅ M84. Velero PVB "prepare timeout" under nightly load — node-agent dataPathConcurrency — FIXED 2026-06-19
- **Source:** 2026-06-19 nightly run. Beyond the H39 firewall fix (proven — most PVBs complete clean incl. a 6.8 GB one), a **subset of PVBs stalled in `Prepared` / `timeout on preparing PVB`** → backups `PartiallyFailed`/`Failed` (06-19: critical-apps, kube-system, monitoring, infrastructure). **Root cause:** no `node-agent-config` ConfigMap → velero node-agent used the default **`dataPathConcurrency=1` per node** — multi-volume backups serialized per node and queued PVBs exceeded the prepare timeout. NOT the firewall, NOT data corruption.
- ✅ **Fixed (`918e101`):** added `configMaps.node-agent-config` (`{"loadConcurrency":{"globalConfig":2}}`) + `nodeAgent.extraArgs: [--node-agent-configmap=velero-node-agent-config]` to `clusters/wind/helm-releases/velero.yaml` (chart-wiring verified against velero 11.4.0 values; CM renders as `velero-node-agent-config`). node-agent rolled 8/8 clean with the flag. **Verified twice** with on-demand backups completing **0 stalls**: infrastructure **20/20 PVBs Completed**, postgres **9/9 Completed** (was Failed). Tonight's nightly should be fully clean.
- **Residual housekeeping:** the 06-19 nightly's stale PartiallyFailed/Failed backups will be superseded by tonight's clean run. **Silence extended (owner-approved 2026-06-19):** replaced `4fe8a806` with **`f7907750`** (same matchers, ns=velero) **expiring 2026-06-20T12:00Z** so the clean nightly supersedes the stale partials before it lifts; `VeleroBackupFailed` is deliberately NOT silenced (a genuine hard failure still pages). Two `m84-verify-*` on-demand backups left as fresh restore points (postgres labeled to the schedule; infra standalone).
- **NB (2026-06-19 nightly was extra-messy from operator actions, not a regression):** postgres backup ended `Failed` because I recreated postgres-cluster-6 mid-window (EIO fix) then deleted its PVBs → velero stuck `InProgress` → I `rollout restart deploy/velero` to finalize+unblock the queue. postgres data is safe regardless (CNPG continuous archiving healthy). Clean on-demand postgres/critical-apps backups + the dataPathConcurrency fix are the close-out (see session-log 2026-06-19).

### ✅ M85. AI advisor — suppress diagnosis email for already-resolved (transient) alerts — DONE 2026-06-19
- **Source:** owner 2026-06-19, after the overnight remediation churn produced ~6 diagnosis emails for issues (dcgm rollout, postgres-6 crashloop, failed velero jobs) that had **already resolved** by the time the emails landed. "If something is truly transient and is resolved by the time the email fires, we don't need an email about it."
- ✅ **Fixed (`ecd37ea`):** added `_alert_still_firing(alert)` to the advisor — queries Prometheus `ALERTS{alertname,alertstate="firing"}` (matched on `namespace` too when present). `_advise` now skips the Claude call **and** the email (audit `skipped_resolved`) when the alert has resolved before the advisor reaches it. **Fail-open** (if the Prometheus check errors, do NOT suppress — never silently drop a real alert); **not cooldowned** on skip so a genuine re-fire still active next time is diagnosed. Validated (py_compile + kustomize), reconciled, `rollout restart deploy/remediation-controller` (new pod healthy). Combines with the once-per-day cap-notice ([[H39]] `93cc970`) + 15min per-alertname cooldown.

### ✅ M86. UNAS SSD-cache member drop (NVMe APST hang) → md-degradation alerting — DONE 2026-06-19
- **Source:** 2026-06-19 incident. A UNAS SSD-cache NVMe (`nvme0`, one of two `md4` RAID1 members) **fell off the PCIe bus** (`CSTS=0xffffffff`, APST controller hang) ~5h after the morning firmware update (`UNASPRO v5.1.19`); `md4` ran **degraded `[2/1]` for hours with no alert**, surfacing only as an SMB hang (the UI showed both SSDs "healthy" — SMART can't report a drive that vanished from the bus). RAID6 data array unaffected; cache RAID1 survivor healthy → no data loss. Reboot re-probed `nvme0`, `md4` auto-rebuilt to `[2/2] [UU]`.
- ✅ **Fixed:** new IaC component **`platform/kubernetes/unas-health/`** — CronJob SSHes the UNAS every 15 min (reuses `unifi-backup-ssh`, host-key pinned), parses `/proc/mdstat`, pushes degraded/active/total gauges to Pushgateway → **`UnasMdArrayDegraded`** + `UnasMdHealthCheckFailing`/`UnasMdHealthStale` watchdogs (`03-prometheusrule.yaml`). Validated (kustomize + awk parser unit-tested). Runbook: [`unas-nvme-cache-apst-hang.md`](../runbooks/unas-nvme-cache-apst-hang.md).
- ⏳ **Watch (recurrence = firmware confirmed):** if `nvme0` drops again on v5.1.19 → report to Ubiquiti (firmware + `CSTS=0xffffffff` APST signature), consider firmware rollback, or swap `nvme0` (different SSD model). Can't persist `nvme_core.default_ps_max_latency_us=0` on the locked appliance. A self-scheduled quiet check pings only on recurrence.

### ✅ M87. cloudwatch-to-loki — baked image (runtime pip eliminated) — DONE 2026-06-20
- **Source:** 2026-06-20 overnight `BackoffLimitExceeded` (runtime `pip install` + `backoffLimit:0`). **Interim (`734fe3f`):** `backoffLimit 0→3` + `pip --retries 5 --timeout 30`. **Image (`734fe3f`):** `image/Dockerfile` bakes `boto3`+`kubernetes>=30,<31`, built by `.github/workflows/cloudwatch-to-loki-image.yml` → `ghcr.io/sparked-diamond/cloudwatch-to-loki` (tags `main` + `sha-`; script stays in the ConfigMap). Owner flipped the package Public (one-time, GITHUB_TOKEN can't for user-owned).
- ✅ **Cutover (`dd29537`):** CronJob → `ghcr.io/...cloudwatch-to-loki:main` + `imagePullPolicy: Always` (same scheme as cloudflare-ddns/aws-s3-sync — no image-automation entry needed), dropped the `pip install` + bash wrapper → `command: ["python","/scripts/forward.py"]`. Verified: run completes with no pip step, k8s auth ok, events pushed. Runtime-pip failure class eliminated.

### ✅ M89. pve-ipmi TargetDown — H37 firewall missing the IPMI exporter allow — FIXED 2026-06-20
- **Source:** `TargetDown` email 2026-06-20T13:16Z (`up{job="pve-ipmi"}=0`). **Root cause:** the H37 default-deny host firewall had **no allow rule for the in-band ipmi_exporter `:9290`**, so Prometheus's scrape of `10.10.200.41:9290` was dropped (timeout, not refused — host up, `:22` open). **Same latent-firewall class as the Ceph oversight** ([[H37]]/Ceph fix `d8fc8d4`) — a needed allow missing from the Stage-2 DROP policy.
- ✅ **Fixed (`96318e3`, applied):** added a `pve-ipmi` security group (tcp `9290` from `var.ipmi_scrape_cidr` = `10.10.201.0/24`, the Servers/K8s VLAN where pod→host scrape traffic is Cilium-masqueraded) + node attachment in `infra/terraform/proxmox/firewall/`. `terraform apply` = 1 add, 1 change, 0 destroy. Verified: `:9290` reachable, `up=1`, 12 IPMI temp sensors reporting. **The PVE host firewall now has THREE required allows: mgmt (22/3128/8006), Ceph (storage VLAN), IPMI (:9290) — see CLAUDE.md §5.**

### ✅ M88. OneDrive → NAS backup (rclone-onedrive) — DONE 2026-06-20
- **Source:** owner 2026-06-20. Mirror of `rclone-gdrive` for a personal OneDrive (M365 personal sub = OneDrive **Personal**, `drive_id F4E003FF4BAE9ABD`). `platform/kubernetes/rclone-onedrive/`: nightly `rclone sync onedrive: → /backup/Graham/OneDrive/` (NAS Backups share → rides the existing NAS→S3 sync), 23:00 PT, `--tpslimit 10`, same Pushgateway metrics + failed/stale/errors/slow alerts.
- ✅ **Live (`a893c00`):** OAuth done on the owner's laptop (`rclone config`), `[onedrive]` block sealed into `04-secret.sops.yaml` (committed encrypted from laptop, `--no-gpg-sign` to dodge the SSH-signing-key gap), secret uncommented in kustomization + component registered in `clusters/wind`. Flux decrypted the secret cleanly; CronJob `onedrive-sync` deployed. **First sync verified**: rclone authenticated, files copying into `/backup/Graham/OneDrive/` (Documents/Pictures/WSP), no errors.
- **Behavior note:** uses `rclone sync` (mirrors — deletions on OneDrive propagate to the NAS copy), matching the gdrive convention. Switch to `rclone copy` if archival/never-delete is wanted.

### ⏳ H38. Internal identity-aware access (forward-auth at Traefik) — kill "internal = trusted"
- **Source:** zero-trust assessment 2026-06-17. **Biggest classic ZT gap:** CF Access is **edge-only**; any LAN host hitting Traefik VIP `10.10.201.70` reaches apps with **no auth**. **Do:** add a Traefik `forwardAuth` gate (Authelia/Authentik/oauth2-proxy, Google SSO + MFA) or Tailscale-serve/tsnet identity in front of internal ingress, sensitive apps first (Grafana, HA, wiki, admin UIs). Also unblocks **L14** (public approval URL auth gate). Spec: [`zero-trust-assessment-2026-06-17.md`](zero-trust-assessment-2026-06-17.md). **Effort:** M–L.

### 🟡 H39. Velero fs-backup incident (wedge since rev5) + AI-advisor email-flood — RESET + HARDENED 2026-06-18, residual under watch
- **Source:** owner 2026-06-18 (advisor email flood + $0.50/day cost cap hit). Root cause = **Velero kopia fs-backups wedged cluster-wide since 06-17 15:30** (helm rev5: [[M5]] resources change + node-agent restart): PVBs `timeout on preparing` → retry storm → daily `PartiallyFailed` backups → the AI advisor emailed on every alert fire until the cap, then kept emailing `[unavailable]` per flapping alertname = the flood. Ruled out capacity/health/repos/version. Full narrative: [`session-log.md`](session-log.md) 2026-06-18.
- ✅ **Resolved cluster-wide (no config gamble):** safe reset — cleared 8 stuck PVBs + data-mover pods, force-cleared wedged finalizers, `rollout restart` velero + 8 node-agents. **Verified** via on-demand `dns` backup: data paths prepare+start cleanly, full 633 MB volume completed, no retry storm. **+ durability** (`93cc970`): pinned velero chart `"11.x"`→`"11.4.0"` (floating range auto-upgraded the backup path with no review). **+ advisor hardening** (`93cc970`): cost-cap notice now once/UTC-day, not per-alertname (audit log unchanged). **+** 24h Alertmanager silence on velero alerts (ID `4fe8a806`, time-boxed).
- 🟡 **Residual (open):** `technitium-1` data PVC on **k8s-w2** hangs **mid-kopia-snapshot at 0 bytes** (sibling on w3 fine) — narrower, volume/node-specific, NOT the rev5 wedge. **Next:** watch tonight's 02:00–05:00 schedules (⚠️ alerts silenced ⇒ no email; check manually); if w2 recurs, investigate the w2 node-agent↔S3/kopia path (possible Cilium-WireGuard/MTU — [[M66]] also landed 06-17).
- ⏳ **Minor:** `PrometheusOutOfOrderTimestamps` fired (monitoring, separate). Optional: raise the advisor `AI_ADVISOR_DAILY_COST_USD_CAP` / lengthen cooldown.

## MEDIUM — quality / hygiene

### ✅ M5. Velero schedule kustomization ordering + ResourceQuota CR — DONE 2026-06-17 (see [[H39]] — rev5 deploy of this change correlated with a fs-backup wedge; resolved by reset, not revert)
- Source: `archive/outstanding-work-2026-05-16.md` M5 ("Schedules currently apply before HR; quotas mentioned in 3 places never written").
- ✅ **Done 2026-06-17** (`clusters/wind/helm-releases/velero.yaml` + velero README):
  - **Ordering — resolved as by-design (no risky restructure):** the `Schedule` CRs sit in the monolithic `clusters/wind` kustomization alongside the velero HelmRelease — the **same CR-after-HelmRelease pattern the whole repo uses** (e.g. monitoring `PrometheusRule`/`ServiceMonitor`). On cold bootstrap the Schedules briefly fail until helm-controller installs the `velero.io` CRDs, then **Flux's retry self-heals**. A restructure (Helm `values.schedules` / separate `dependsOn` Kustomization) was rejected — zero gain on a healthy cluster, and the kustomize↔Helm ownership cutover risks deleting live Schedules on a critical backup path. Documented in the velero README.
  - **Quota → safe alternative:** a namespace `ResourceQuota` is **unsafe here** — velero's pods declared **no resource requests** (all `BestEffort`), so any compute quota would silently reject ephemeral backup/restore/kopia-maintenance pods (= silent backup failure). Instead added resource **`requests` only (no limits)** to velero server (250m/256Mi) + node-agent (200m/256Mi): promotes both to `Burstable` QoS (node-agent less likely evicted mid-backup ⇒ more reliable backups), with **no limits** so Kopia can't be OOM-killed on large repos. Lays groundwork for a future *requests-based* quota after profiling. Rationale in the velero README. `kubectl kustomize clusters/wind` builds clean.

### ⏳ M6. Packer + ansible netplan dedup (F1.3)
- Source: `archive/outstanding-work-2026-05-16.md` M6.

### ⏳ M10. Lifecycle / `ignore_changes` on Proxmox K8s VMs (F1.5)
- Source: `archive/outstanding-work-2026-05-16.md` M10.

### ⏳ M11. DR runbook with measured RTO/RPO targets
- Source: task #23. Needs your judgment on targets before measurement.

### ⏳ M12. CNPG restore drill Tier B (sibling cluster)
- Source: task #24. Destructive test; needs supervision and maintenance window.

### ⏳ M14. Investigate aws-s3-sync daily-report SSL mismatch (if recurs)
- Source: task #25. Only act if it recurs.
- **Note on ID:** the *archived* outstanding-work-2026-05-16.md used M14 for a UDM WireGuard cleanup item; some older cross-references (e.g. `docs/architecture/firewall-zones.md`) still point at that older meaning. To disambiguate, that WireGuard cleanup is now M42 (below). The two are unrelated.

### ⏳ M15. Twilio Talk: fix 911 emergency address
- Source: task #20. Out-of-band (Twilio console).

### ⏳ M16. Twilio Talk: route or release orphan DID
- Source: task #21. Out-of-band.

### ⏳ M17. Twilio Talk: migrate SIP trunk UDP → TLS+sRTP
- Source: task #22. Out-of-band.

**Evidence / loose end (spotted 2026-06-12 in Loki):** the UDM logs a recurring
`ubios-udapi-server ... firewall: Destroying set(s) unifi_talk_addresses, unifi_talk_ports failed and will retry soon: command ipset ...`
(seen 06-05). The Talk firewall ipsets fail to tear down cleanly — likely
stale Talk firewall state on the UDM. Worth clearing while doing the Talk
work above (M16 DID release / M17 SIP migration) so the sets aren't
orphaned. Not service-affecting on its own.


### ✅ M53. Mint zone-scoped CF API tokens (de-couple infra ↔ personal-web) — DONE 2026-06-17
- **Done (owner):** zone-scoped Cloudflare token minted + personal-web's `CLOUDFLARE_API_TOKEN` cut over to it, decoupling the two repos from the shared account-scoped token. (The Single-Redirect/Ruleset scope that this unblocked is now used in the personal-web repo, where **M54** also moved.)

### ➡️ M54. Codify smithforsb.com redirect (CF Single Redirect) as IaC — MOVED to personal-web repo (2026-06-17)
- **Closed here:** ownership of the `smithforsb.com` redirect moved entirely to the **personal-web** repo (it's a personal-web concern, codified alongside `cloudflare-dns/smithforsb.tf` there). No longer tracked in this infra repo. ID retained for grep history.

### ✅ M55. UniFi telemetry exporter (unifi-poller) — LIVE
- **Source:** 2026-05-30. UDM observability is logs-complete but metrics-thin. Syslog → Alloy → Loki works (UDM-Pro-Max actively shipping, verified). But Prometheus has NO full UniFi telemetry — only `probe_success` (blackbox reachability, fixed 2026-05-30) + `unifi_backup_*`. Missing: client counts, throughput, WAN, port/PoE, AP/client RSSI, per-device health.
- **Scope:** deploy unpoller (unifi-poller) as a Deployment scraping the UDM controller API → Prometheus `ServiceMonitor` (must carry label `release: monitoring`, per the probeSelector lesson) → Grafana dashboards. Needs a read-only UniFi local account + creds (SOPS secret). Keep the UI/API access internal (Tailscale-only constraint).
- ✅ **LIVE** (activated commits `75aec6f`/`d5c9e3d`): `platform/kubernetes/unifi-poller/` (Deployment v2.15.3 + Service + ServiceMonitor `release: monitoring`) is wired into `clusters/wind/kustomization.yaml` with the SOPS secret; deployment Running. Dashboard IDs in the dir README.
- **Effort:** S remaining (account + secret + uncomment + import dashboards).

### ✅ M56. Servers/201 → Trusted zone + Management split — COMPLETE 2026-05-31
- **Done:** two-zone split instead of one — **`Trusted` = {Servers/201}`**, **`Management` = {200}** (contained), `Internal` keeps Default/199. Production-aligned management-plane isolation. 20 v2 firewall-policies codified in `infra/ansible/playbooks/udm-firewall.yml` (applied via `ansible-unifi.yml` CI). Design + posture in `docs/architecture/firewall-zones.md`.
- **DNS `.5` stays on 201** (network-wide contract; see M59) — not re-IP'd.
- **Gotcha hit + fixed:** custom zones default **intra-zone to BLOCK** (built-in Internal doesn't) → the cluster→AWS hairpin (static route next-hop `.20`, back inside 201) was evaluated `Trusted→Trusted` and dropped → dns-aws/vpn-aws TargetDown. Fixed with an explicit `Trusted→Trusted (all)` allow. See [[reference_udm_custom_zone_intra_block]].
- **Verified:** cross-zone probes (Protect/Infra, UDM/Mgmt, UNAS), unifi-poller, AWS nodes recovered + alerts cleared, UNAS (zoneless 209) resolves via `.5` (east-west switch-routed, bypasses UDM zones). Remote WG intact.
- **Management is contained:** `Management→Trusted` is strict — DNS (port 53 → `.5/.6`) + syslog (udp/514 → Alloy `.73`) only, everything else default-blocked (+ stateful returns for Trusted-initiated flows). `Management→{IoT,Security,Guest,Internal,Infra,Vpn}` denied.

### ⏳ M58. Periodic: recheck for a UDM BGP config API → promote UDM BGP to IaC
- **Source:** 2026-05-31 (BGP Phase C/D). The MetalLB↔UDM BGP works, but the **UDM side is UI-only** — UniFi Network 10.4.57 exposes no usable API endpoint for the BGP/FRR config (`rest/routing/bgp` + `stat/routing/bgp` empty, `get/setting` + device object + v2 routing paths don't carry it). So it can't be a `udm-bgp.yml` Ansible push; durability today = git-stored FRR config (`docs/runbooks/bgp-phase-c-udm-metallb.md`) + the daily controller backup.
- **Action (cadence = on each UniFi Network upgrade; the API only changes with releases — a time-based cron is the wrong tool, it'd expire):** re-probe those endpoints; if one now returns/accepts the BGP config, write `udm-bgp.yml` (the `udm-firewall.yml` pattern) and promote the UDM BGP to full IaC.
- **Effort:** S to recheck; M to build the playbook once an endpoint exists.


### ⏳ M35. Wire dns-aws public IP as 3rd DHCP DNS resolver
- **Source:** user ask 2026-05-23. Rationale: with `.5` (Technitium cluster VIP) primary + `.6` (dns-fallback VM) secondary, any combined outage of both the K8s cluster + the on-prem fallback + the AWS WG tunnel leaves clients with no DNS. Wiring dns-aws's public IP (currently `52.40.219.113`, the EIP of the dns-aws EC2 instance) as a 3rd DHCP DNS gives clients a path over the public internet even when the tunnel is down.
- **Already in place:** the `dns_server` SG on AWS allows port 53 TCP+UDP from the homelab WAN IPs (`66.215.210.75` + `47.159.189.5`), kept in sync with `wan1`/`wan2.wind.etherport.net` Route53 records by the dns-restrict-ip Lambda. So clients reaching `52.40.219.113:53` from the homelab WAN will succeed.
- **Fix:** for each tenant VLAN with DHCP DNS set to `.5/.6` today (Management, Servers, Clients, IoT, vSAN, Ceph, Unifi per M25 audit §1.6), add `52.40.219.113` as a 3rd entry. UDM UI per-network or via the `paultyng/unifi` TF provider if codifying. Skip Guest (already uses public DNS by design).
- **Effort:** S — UI clicks or one TF block per network.

### ⏳ M42. UDM WireGuard cleanup (renumbered from archived M14)
- **Source:** carried forward via `docs/architecture/firewall-zones.md` cross-reference. Original archive ID was M14 but that's now reused for the s3-sync SSL probe item above. ID rotated to M42 to disambiguate.
- **Effort:** S. Walk the UDM WG peer list, drop stale entries (likely vpn-mumbai before M38 destroyed it — verify), confirm wg0_regional_peers in `infra/ansible/playbooks/wireguard.yml` matches.

### 🟡 M41. Plex log centralization + AI-augmented alert remediation
- **Done partial:** 2026-05-23 (commits `77a9ee0` `30d7f20` `062b3b1`).
- **Phase 1 of the advisor SHIPPED but is OFF by default.** Controller pod is rolled with the new code, prompt ConfigMap, two SOPS-encrypted secret placeholders (anthropic-api-key, smtp-credentials), and `AI_ADVISOR_ENABLED=false`. To turn on: see `docs/runbooks/archive/ai-advisor-phase1-enable.md`. Requires (a) creating a dedicated Anthropic API key, (b) populating the two SOPS secrets, (c) flipping the deployment env. All three need user action — Anthropic console isn't agent-accessible, and the existing SMTP creds can't be auto-mirrored cross-namespace without writing plaintext to disk (correctly blocked by the sandbox).
- **Plex sidecar:** Plex writes its real logs to `/config/Library/Application Support/Plex Media Server/Logs/*.log` not stdout, so the cluster-wide Alloy scraper had been seeing only the s6 init lines. Added `logtail` busybox sidecar to `platform/kubernetes/plex/02-deployment.yaml` that mounts the config PVC read-only and `tail -F`'s the log dir. Logs now query as `{namespace="plex", container="logtail"}`. **Immediate win:** centralized logs caught a real Plex config bug — `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument` repeating ~constantly. The space-separated entries look like Plex Web UI Library Settings → Network → "LAN Networks" was set with `; ` separators colliding with the env-var `ALLOWED_NETWORKS` setting. Tracked as L6 below.
- **Syslog labeling:** Alloy now promotes `__syslog_message_hostname` / `app_name` / `severity` / `facility` and `__syslog_connection_ip_address` to real Loki labels (`host`, `app`, `source_ip`). Required the `relabel_rules = loki.relabel.X.rules` pattern on the syslog source itself (not a downstream `forward_to` chain — first attempt got that wrong; fixed in `2839623`). Confirmed: `host` label values now include `UDM-Pro-Max`, `AMI9C6B006A1B39` (PVE BMC), `APBasement`/`APDeck`/`APDownstairs`/`APDriveway`/`APWorkroom`.
- **AI advisor spec:** `docs/planning/archive/ai-alert-remediation-2026-05-23.md` — full design for extending the existing M8 auto-remediation webhook with a Claude API path that handles alerts falling through the rule-based dispatch. Three-mode safety model (advisory/propose/auto), hard guardrails enforced in code not prompt, ~$5/mo cost estimate. Phase 1 (advisory-only) is ready to build pending user decisions on Slack-vs-email sink + API key.
- **Open:** build Phase 1 of the advisor. ETA 1 week of implementation.

### 🟡 M47. UDM Network App modernization — API key + Integration API
- **Status 2026-05-26:** scoping runbook landed at `docs/runbooks/archive/udm-network-app-modernization.md` (commit `de65e29`). Auth migration is ~half-day work; the URL migration to `/proxy/network/integration/v1/...` is partial-coverage (firewall groups have no Integration equivalent yet) so the recommended path is auth-only swap first, defer URL migration until UniFi Network 10.2+. Awaiting user to create the UDM API key (one-time console action).
- **Original entry below.**

### ⏳ M47-orig. UDM Network App modernization — API key + Integration API
- **Source:** 2026-05-26 audit while working Twilio Talk (#22). Found that `infra/ansible/playbooks/udm-firewall.yml` still uses the legacy username/password + `POST /api/auth/login` cookie auth flow against `/proxy/network/v2/api/...` and `/proxy/network/api/s/...`. UniFi Network Application ≥10.1.84 ships an official **Integration API** at `/proxy/network/integration/v1/...` with API-key auth (`X-API-Key` header), which is more durable + key-rotatable than the cookie dance.
- **Scope:**
  - User creates UDM API key in console → Control Plane → Admins → Create API Key. Stored in 1P as `unifi-udm-api` (API Credential category: `credential` = key value). Least-privilege scope; only widen if a playbook requires it.
  - Add `udm_api_key` to `infra/ansible/inventory/group_vars/all/secrets.sops.yml`.
  - Update `udm-firewall.yml` (+ any future UDM playbooks) to swap login flow → `headers: { X-API-Key: "{{ udm_api_key }}" }`.
  - Where Integration API covers the resource, migrate the endpoint (`/proxy/network/integration/v1/sites/{site}/...`); where it doesn't, keep `/proxy/network/v2/api/...` but with the new auth header (still supported).
  - Add `UNIFI_UDM_API_KEY` GH Actions secret for CI runs.
- **Effort:** ~half day. Mirror the auth-modernization pattern used elsewhere.
- **Source:** memory `reference_udm_zone_policy_api.md` for current state.

### ✅ M48. UNAS — config-as-code state backup (2026-05-31)
- **Done (state-backup path):** UNAS config is UI-managed (internal Postgres, no clean write-API), so instead of write-IaC we keep a **human-readable snapshot in git**: `infra/unifi-devices/unas/` — `config-snapshot.md` (device, network, 9 shares, 5 users, authoritative NFS export ACLs) + `snapshot.sh` (regenerates read-only over SSH via the `unifi-cert-sync@homelab` key, now provisioned on the UNAS) + README with rebuild notes. Closes the gap where the UNAS was backed up nowhere.
- **Open option (parked):** true write-IaC via the UNAS **API-key** Integration API was NOT tested — would need an API key minted in the UNAS app + endpoint discovery. Revisit only if the config-as-code snapshot proves insufficient.

### ✅ M49. UniFi Protect — config backed up to S3 (verified 2026-05-31)
- **Done:** Protect's `core-config` already rides the daily `unifi-backup` CronJob → S3 (`protect/core-config`, last run Complete). Verified healthy. No new work.
- **Open option (parked):** write-IaC (camera/retention config) via the Protect API-key Integration API — same untested path as M48; deprioritized.

### ✅ M50. UDM/UNAS/Protect IaC coverage — assessed 2026-05-31
- **Outcome:** UDM is the one with a real config API (zones/policies codified via `udm-firewall.yml`; firmware/routes/etc. via TF). UNAS + Protect are UI/DB-managed appliances → covered by **backups** (UNAS git snapshot + Protect/UDM S3), not write-IaC. Write-IaC for the appliances is parked pending the API-key Integration API maturing. A full UI-page-by-page coverage table (`udm-iac-coverage.md`) remains a nice-to-have if deeper auditing is ever wanted.

### ⏳ M51. UniFi Talk IaC — DEFERRED pending public API
- **Source:** 2026-05-26 research during Twilio Talk #22 work. Investigated whether UniFi Talk 3rd-party SIP provider config can be managed as IaC; conclusion = no public API exists today, and reverse-engineering the `/proxy/talk/...` endpoints is feasible (1-2 days) but undocumented (Ubiquiti can change them silently on any upgrade).
- **Decision:** wait for Ubiquiti to ship a public Talk API. Track via the open community feature request. Until then, the SIP provider config in [twilio-talk.md](../runbooks/twilio-talk.md) is the source-of-truth (UI-managed, documented).
- **Trigger to revisit:** Ubiquiti announces Talk API support.
- **Effort when unblocked:** ~1 day to write the playbook.

### ⛔ M59. Dedicated LB VLAN for MetalLB VIPs — PARKED + backed out 2026-05-31
- **Decision:** not worth it. The foundation (VLAN 215 + `lb-vlan` pool + `lb-vlan-bgp` advertisement) was built, but because Servers/201 + LB would share the **same `Trusted` zone**, moving VIPs onto a 215 subnet buys **no segmentation** — only cosmetic addressing. And a zero-downtime cutover isn't cleanly possible: MetalLB rejects two IPv4s on one service (`same address family`), so the dual-home attempt failed and briefly scared the live ingress/BGP. Spending live-traffic risk on address hygiene is a bad trade.
- **Backed out fully:** removed the TF network (`unifi_network.loadbalancers` → VLAN 215 destroyed), the MetalLB `lb-vlan` pool + advertisement, and the migration runbook. All VIPs stay on 201 (BGP-advertised, working). The `.5` DNS pin decision still stands (it's a network-wide contract; stays on 201 regardless).
- **If revisited:** only worth it if LB VIPs get their **own** zone (DMZ-style for service front-ends) — then re-create 215 as its own zone, not bundled with `Trusted`.

### ✅ M60. Secret-scanning in pre-commit + CI (gitleaks) — 2026-06-11
- ✅ `gitleaks` pre-commit hook (2026-06-10) **+ CI `secret-scan.yml`** (2026-06-11) — runs on every PR + push to main (closes the client-side-only gap; the mini auto-pushes to main per L20). Added `.gitleaks.toml` with a verified allowlist (SOPS templates, doc examples, the SES SMTP access-key *ID* — confirmed no real plaintext-secret leaks in the tree).

### 🟡 M61. Expand pre-commit + Renovate coverage
- Review 2026-06-10. ✅ **Landed 2026-06-10:** `terraform_tflint` (+ minimal `.tflint.hcl`) + `shellcheck` pre-commit hooks.
- ✅ **Done 2026-06-17:**
  - **SOPS centralized:** the 3 terraform workflows that still curl'd SOPS inline (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn` — all `ubuntu-latest`/amd64) now `uses: ./.github/actions/setup-sops` (pinned + **checksum-verified**, single source of truth for the version). Also closes the H30 "wire 3 workflows to setup-sops" deferred item. (Verified: 0 inline `releases/download/v3.9.4/sops` curls remain in `.github/workflows/`; YAML lints clean.)
  - **Renovate coverage:** enabled the `pre-commit` **manager** (off by default → now bumps the 4 externally-pinned hook repos: pre-commit-terraform, yamllint, shellcheck-py, gitleaks); added explicit `packageRules` grouping the `github-actions`, `terraform`, and `pre-commit` managers into tidy per-area PRs. (`github-actions` + `terraform` managers/datasources were already active via `config:recommended` — now intentionally grouped.) renovate.json validates.
  - **ansible-runner Dockerfile:** can't reuse the composite action (it's a build, not a workflow) + is arch-dependent; already pinned to the same `v3.9.4`. Added a sync-pointer comment to `setup-sops` (the canonical version) + a `TODO(M61/H30)` for per-arch sha256 verification.
- ⏳ **Remaining:** `ansible-lint` pre-commit hook — still deferred (needs a baseline-noise suppression pass first or it floods every commit). **Effort:** S remaining.

### ✅ M62. etcd snapshots → offsite (S3) + freshness alert (supersedes L15) — DONE 2026-06-17
- Review 2026-06-10. `etcd-backup.yml` wrote local-disk only (14d); offsite only via Velero's `kube-system-daily` — the exact path that silently `PartiallyFailed` ≥4d recently. If a CP node is lost, its snapshots go with it; no freshness alert.
- ✅ **Authored 2026-06-16 (validated; applies pending):**
  - **TF** (`infra/terraform/aws/s3/`): dedicated **`etcd-snapshots.wind.etherport.net`** bucket — STANDARD storage, 30d expiry, versioned, public-access-blocked (NOT the `archive` bucket: it Deep-Archives in 2d → ~12h retrieval, wrong for DR). Scoped **`etcd-backup`** IAM user (PutObject-only to the bucket; mirrors `postgres_barman`). Access-key outputs added.
  - **Playbook** (`etcd-backup.yml`): installs awscli + drops scoped creds at `/root/.aws/credentials`; `etcd-snapshot.sh` now `aws s3 cp`s each snapshot to `s3://…/<host>/` AND pushes `etcd_snapshot_last_run_timestamp` / `_size_bytes` / `_s3_upload_success` to **Pushgateway** (pinned ClusterIP `10.43.32.171`, set in `helm-releases/pushgateway.yaml`).
  - **Alert** (`monitoring/06-backup-alerts.yaml`): `EtcdSnapshotStale` (>36h, critical) + `EtcdSnapshotS3UploadFailing` (warning). namespace `kube-system` → advisor advisory-only (etcd is human-in-the-loop).
- ✅ **(1) terraform applied 2026-06-17** via CI (`terraform-s3.yml`, run 27660286692) — bucket + `etcd-backup` IAM live. (First apply failed on an invalid archive tag char; fixed + re-applied green.)
- ✅ **(2) SOPS secret created** — `infra/ansible/playbooks/secrets/etcd-backup.sops.yaml` (scoped creds from TF outputs, both age recipients), committed `c9b64de`.
- ✅ **Alerts + pushgateway pin LIVE via Flux** (`c9b64de` reconciled; `EtcdSnapshotStale` + `EtcdSnapshotS3UploadFailing` present, pushgateway ClusterIP pinned). (Flux apply was briefly blocked by the unrelated CNPG webhook-cert incident — see session-log 2026-06-17 — now resolved.)
- ✅ **(3) Playbook ran 2026-06-17** via CI (`ansible-vm-fleet.yml`, etcd-backup, limit=kube_control_plane). **Verified end-to-end:** all 3 CP nodes uploaded snapshots to `s3://etcd-snapshots.wind.etherport.net/<host>/` (~205MB each), and Prometheus shows `etcd_snapshot_last_run_timestamp` (fresh), `etcd_snapshot_s3_upload_success=1`, `etcd_snapshot_size_bytes` for all 3.
- **Wrinkle (resolved):** Ubuntu 24.04 dropped the `awscli` apt package (not in universe either) → switched to the **AWS CLI v2 official installer, sha256-pinned** in the playbook (`d0f7ec7d…`; fail-closed on artifact rotation). **M62 DONE.** (L15 superseded — the metric+alert replaces the journal-to-Loki idea.)

### 🟡 M63. k8s manifest hardening sweep
- Review 2026-06-10. Per-workload gaps: (a) `cloudflared` ServiceMonitor missing `release: monitoring` label → metrics never scraped; (b) `rclone-gdrive` CronJob has NO securityContext (runs root); (c) no `startupProbe` on slow-boot workloads (technitium DNS, home-automation, wikijs, ollama) → restart risk mid-rollout; (d) no PDB for 2-replica `cloudflared`; (e) home-automation `privileged: true` → scope to explicit caps + device mounts. Small per-file fixes; template the hardened securityContext (cue-api/cloudflared already do it right). **Effort:** M (sweep).
- 🟡 **Done 2026-06-17 (safe trio a/b/d):** (a) added `release: monitoring` to the cloudflared ServiceMonitor; (b) added a **conservative** container securityContext to the rclone-gdrive CronJob (`allowPrivilegeEscalation: false` + `capabilities.drop:[ALL]` + `seccompProfile: RuntimeDefault`; deliberately **NOT** `runAsNonRoot`/`readOnlyRootFilesystem` — rclone writes its working config to an emptyDir and the image's user expectations are untested, so those stay off to avoid breaking the nightly sync); (d) added a `minAvailable: 1` PDB for the 2-replica cloudflared Deployment (`platform/kubernetes/cloudflared/03-pdb.yaml`). All three `kubectl kustomize`-validated.
- ⏳ **Deferred (need care, not "safe trio"):** (c) `startupProbe`s — technitium is the cluster's split-horizon DNS; a misjudged probe could wedge DNS mid-rollout, so this needs per-workload boot-time measurement first. (e) home-automation `privileged: true` → explicit caps + device mounts — needs the owner's knowledge of exactly which host devices (Zigbee/Z-Wave USB, etc.) HA needs before narrowing, or it'll break device access.

### ⏳ M64. Image-pinning model — pick one and apply repo-wide
- Review 2026-06-10. Mixed: 18 manifests auto-update via Flux `$imagepolicy`, ~10 use hardcoded floating tags. Decide canonical (Flux ImagePolicy+digest everywhere, or pin-by-digest + manual bump) and apply; document which apps auto-update vs frozen. Ties to **H30**. **Effort:** M.

### ✅ M65. Terraform consistency — version pins, DRY, hardcoded IDs — DONE 2026-06-17
- Review 2026-06-10. (a) `required_version` ranges differ across stacks (`>= 1.0` … `>= 1.5.0`) while CI pins 1.14.3 — standardize to `>= 1.14`. (b) `unifi/networks.tf` repeats a 10-line `lifecycle.ignore_changes` block ×11 — extract to a `local`. (c) `aws/compute/main.tf` hardcodes VPC/subnet/SG IDs + the automation SSH pubkey (duplicated in 3 places) — source from module outputs / a shared var. (d) proxmox stacks hardcode the PVE endpoint ×3 → shared var. **Effort:** M.
- ✅ **Done 2026-06-17** (zero plan-diff — verified):
  - **(a)** All **22** `required_version` constraints standardized → `>= 1.14` (local TF 1.15.5, CI pins 1.14.3 — satisfied everywhere). `terraform fmt` also normalized pre-existing whitespace drift in `aws/twilio-webhook/{iam,main}.tf`.
  - **(c)** `aws/compute`: hoisted the 6 hardcoded data-source IDs (VPC/subnet/4×SG) + the inline cloud-init automation pubkey into `variables.tf` (defaults = current live values). **`terraform plan` = "No changes"** (data sources resolve to identical IDs; user_data has `ignore_changes`). True cross-stack dedup of the pubkey isn't possible from one TF var (it also lives in `proxmox/{k8s-vms,standalone-vms}/variables.tf` + `pve-sshd.yml`) — variable now carries a comment pointing to all placements.
  - **(d)** `proxmox/{k8s-vms,sdn,standalone-vms}`: PVE endpoint → `variable "proxmox_endpoint"` (default = `https://pve.wind.etherport.net:8006/api2/json`). All 3 `terraform validate` clean.
  - **(b) NOT DONE — infeasible by design:** Terraform forbids `locals`/vars inside `lifecycle.ignore_changes` (it takes unquoted attribute refs only) — the file *already documents this* (`unifi/networks.tf` lines 17-19), and the 11 blocks aren't even identical (the `unifi` network adds `dhcp_dns`). The only DRY route is converting all 11 `unifi_network` resources into a single `for_each` module with `moved` blocks for every address — a risky state-churn refactor for marginal gain. Left as-is (the explanatory in-file comment is the mitigation). **If ever revisited:** module-ize under `modules/unifi-network/` + `moved {}` per resource; treat as its own item.
- **Validation:** aws/compute `plan` = No changes; proxmox ×3 `validate` = valid; `terraform fmt -recursive -check` clean. Not applied (authoring only — applies ship via CI/owner per the safety rule).

### ✅ M66. Cilium pod-to-pod encryption — ENABLED (WireGuard) 2026-06-17
- Review 2026-06-10. `cilium_encryption_*` commented out (off). With BGP now spanning VLANs (wider trust boundary) + no NetworkPolicies (H3), east-west pod traffic (incl. postgres replication, WG key material) is cleartext + unrestricted. Either enable WireGuard-mode Cilium encryption or document the accepted risk. **Effort:** M (or doc-only).
- **Decision (owner 2026-06-17):** enable WireGuard, staged.
- ✅ **Done 2026-06-17 — verified live:**
  - **State before:** Cilium v1.18.6, `routing-mode: tunnel`/vxlan, `kube-proxy-replacement: false`, encryption off → pod-to-pod was cleartext VXLAN over the node underlay.
  - **Applied** via the Helm release (`cilium`/kube-system, no kubespray run → avoids the cni-owner landmine): `helm upgrade cilium cilium/cilium --version 1.18.6 --reuse-values --set encryption.enabled=true --set encryption.type=wireguard` (dry-run first confirmed the **only** delta = `enable-wireguard: "true"`; full values backed up to `/tmp` first), then `kubectl rollout restart ds/cilium` (maxUnavailable 2, rolled clean).
  - **Verified:** `cilium-dbg encrypt status` → `Encryption: Wireguard`, `cilium_wg0`, **7 peers** (full mesh, all 8 nodes), `NodeEncryption: Disabled` (pod-to-pod only). All 8 CiliumNodes published wg pub-keys. **Postgres stayed 3/3 healthy** across 3 nodes through the roll; **0 unhealthy pods** cluster-wide. WireGuard is kernel-mode (no IPsec secret needed).
  - **Durability:** set `cilium_encryption_enabled: true` + `cilium_encryption_type: "wireguard"` in the kubespray inventory (`k8s-net-cilium.yml`) so a future kubespray run keeps it. Live ConfigMap (helm rev 17) + inventory now agree. Documented in CLAUDE.md §5 + the cilium runbook.
  - **Notes:** NodeEncryption (host-to-host) left off — pod-to-pod covers the stated risk (replication/keys/secrets). MTU auto-adjusts for VXLAN+WG (Cilium `MTU: 0` = auto). Reversible: `--set encryption.enabled=false` + rollout restart.

### ✅ M67. Reconcile dead/contradictory Velero alerting config — DONE 2026-06-17
- Review 2026-06-10. `backups/velero/values.yaml` had `serviceMonitor.enabled: false` contradicting the live HelmRelease (`true` inline since 2026-05-24); `06-backup-alerts.yaml` said rules "stay dormant until the SM exists."
- ✅ **Done 2026-06-17:** that values.yaml turned out to be the **documented manual-bootstrap reference** (already carries a "⚠️ REFERENCE ONLY — Flux doesn't read this" header), not dead — so **mirrored** its SM setting to `true` (+ `release: monitoring`) instead of deleting, so the two no longer contradict. Updated the stale `06-backup-alerts.yaml` comment (SM is enabled + scraped). **Confirmed live:** velero SM exists (23d), `velero_backup_last_successful_timestamp` + `velero_backup_partial_failure_total` = 12 series each in Prometheus, so `VeleroBackupFailed`/`VeleroBackupPartial`/`VeleroLastBackupAgeHigh` evaluate against real data. (`4b8c490`)

### ✅ M68. Documentation consolidation + accuracy pass — DONE 2026-06-17
- Review 2026-06-10. ✅ **Landed 2026-06-10:** (a) staleness banners on the Route53 docs `ubiquiti-ddns.md` + `1PASSWORD-CLI.md` (+ fixed the dead `ooefsxjnvx4khtbh63tn5fr3pu` item ref, filled the real Terraform key ID, pointed to `SOPS-SETUP.md` as canonical); (b) archived `metallb-bgp-migration-2026-05-29.md` + `networking-prod-review-2026-05-31.md`.
- ✅ **Done 2026-06-17:**
  - **(c)** Merged `1PASSWORD-CLI.md` → `SOPS-SETUP.md` — added a concise, **de-staled** "1Password CLI (`op`) quick-reference" section (corrected the old claim that an agent can run `op`: it's **operator/VNC-only**; headless path = the SOPS bundle). `1PASSWORD-CLI.md` is now a redirect stub (kept so the ~5 inbound links don't 404).
  - **(d)** Created `docs/runbooks/archive/README.md` — indexes the archived runbooks, with the **BGP-phase A→B→C** trilogy ordered + outcomes, plus AI-advisor (live-but-enablement-archived), DNS/DDNS→CF migrations, and other completed migrations.
  - **(e)** `docs/README.md`: updated the Secrets rows (SOPS-SETUP canonical; 1PASSWORD-CLI = merged stub), **added a Network subsection** (`setup/network/ubiquiti-ddns.md`, marked superseded), **fixed the broken** `planning/firewall-zones-future-state.md` link → the archived `…-2026-05-29-completed.md` path, and clarified the **AI-advisor** entry ("system is LIVE; the per-phase enable runbooks are archived because enablement is done, not because it's retired"). (remote-state-backend was already indexed.)
  - **(f)** `firewall-zones.md`: added the **M14 → M42 ID-disambiguation footnote** (the doc already used M42, not M14) + fixed its own broken `firewall-zones-future-state.md` reference → archived path.
  - **Note:** archive snapshots (`udm-rule-consolidation.md`, etc.) still name the old `firewall-zones-future-state.md` path — **left as-is** (frozen historical records; rewriting them would be revisionist).
- **Effort:** done.

### ⏳ M70. Protect webhook follow-ups (after the 2026-06-15 fix)
- **Confirm all 5 Alarm Manager URLs flipped** to `http://10.10.201.70:8088/api/webhook/<id>` (IP-literal + plain-HTTP — Protect's hostname-webhook bug). Owner updated some via the Protect UI; verify none remain on `https://`/hostname or the old `https://10.10.202.25/...-bY8...`. **UI-only** (no Protect write API for Alarm Manager). Test after dark — the automations carry a `condition: sun` (sunset→sunrise) so daytime tests won't actuate lights (by design).
- **(optional)** add the `protect-tf` 1P key to the SOPS bundle for headless Protect *integration*-API reads (camera/motion state into HA). Read-only; not needed for the webhook fix.
- **(optional, owner-declined)** source-lock the `:8088` route to Protect's IP. Blocked by Traefik LB `externalTrafficPolicy: Cluster` (SNATs client IP → `ipAllowList` 403s). Would need `externalTrafficPolicy: Local` (cluster-wide) or a UDM firewall rule. Marginal for a LAN-only, path-scoped, secret-ID-gated endpoint. See [`session-log.md`](session-log.md).
- **Effort:** S (verify) / done otherwise.

### ⏳ M71. AWS CLI auth modernization — kill standing static keys on the mini + terminals
- **Source:** 2026-06-17 review (after H29 close). Current state = **long-lived static IAM access keys in plaintext** `~/.aws/credentials` (mode 0600) on the headless mini: `[homelab]`=terraform-homelab (6 `terraform-*` service policies, **no IAM** → bounded, can't self-escalate; key created 2025-12-31, never rotated) and `[claude-admin]`=PowerUserAccess break-glass (created 2026-04-01, never rotated). At rest protected only by FileVault + file perms. **Owner accepts this risk for now** (single-owner, tailnet-only, FileVault) — this item is the **medium-term proper fix**, not urgent.
- **Target architecture:**
  - **Headless mini → [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html).** X.509 trust anchor (CA) + per-host cert + `aws_signing_helper` as a `credential_process` → short-lived session creds, **zero standing key**. The blessed pattern for a persistent on-prem host. SSO is a poor fit here (needs periodic interactive login → breaks headless cron). Setup: trust anchor, cert issuance/rotation, profile per role.
  - **Human/interactive laptops → IAM Identity Center (SSO).** `aws sso login`, short-lived + per-user + MFA. Fine where interactive login cost is acceptable.
- **Cheap interim wins (can do anytime, owner-deferred for now):** (a) remove the `[claude-admin]` PowerUser block from the mini's standing creds — pull from SOPS / use from laptop only when break-glass is actually needed (biggest blast-radius cut for ~0 effort); (b) rotate both keys + set a cadence (terraform-homelab can't rotate itself — do from claude-admin/gs_admin).
- **Effort:** M (Roles Anywhere) + S (interim a/b). See session-log 2026-06-17 for the full blast-radius assessment.

### ⏳ M72. Pod Security Admission: progress audit/warn → enforce
- **Source:** zero-trust assessment 2026-06-17. `policy-baseline/` runs PSA in **audit/warn only** (Phase 1 by design) — violations logged, still admitted. **Do:** review the audit log (observation window elapsed since 2026-05), flip `pod-security.kubernetes.io/enforce: baseline` (→ `restricted` where workloads allow) per ns, documented exceptions for `wireguard`/`blackbox` (privileged). Same per-ns opt-in model as H3. Spec: [`zero-trust-assessment-2026-06-17.md`](zero-trust-assessment-2026-06-17.md). **Effort:** S–M.

### ⏳ M73. Admission policy engine (Kyverno) — image provenance + guardrails
- **Source:** zero-trust assessment 2026-06-17. No policy engine. **Do:** deploy Kyverno (audit→enforce): block unsigned images (cosign — ties **H30**), disallow floating `:latest` (ties **M64**; cue-api is the intentional exception), require resource requests/limits, gate privileged. Pairs with M72. Spec in the assessment doc. **Effort:** M.

### ⏳ M74. Cilium Tetragon — eBPF runtime security / detection (assume-breach)
- **Source:** zero-trust assessment 2026-06-17. We have Cilium/Hubble (flow visibility) but no **runtime** detection. **Do:** deploy Tetragon (Helm), default observability policies on tier-1 namespaces, events → Loki/alertmanager + AI advisor. Spec in the assessment doc. **Effort:** M.

### ⏳ M75. In-cluster workload identity for cloud access (kill long-lived IAM secrets in etcd)
- **Source:** zero-trust assessment 2026-06-17. velero/etcd-backup/rclone auth to AWS with **long-lived static IAM keys in K8s Secrets** — same standing-credential class H29 killed in CI / M71 targets on the mini. **Do:** stand up an IAM **OIDC provider for the cluster SA issuer** (IRSA-style) → pods assume roles for short-lived creds, no static keys in etcd. Migrate the consumers off `existingSecret`. Extends [[H29]]/[[M71]]. Spec in the assessment doc. **Effort:** M–L.

### ⏳ M77. Selective PVE VM firewalling (standalone VMs; k8s nodes EXCLUDED)
- **Source:** H37 follow-on 2026-06-17. Phase 2 of the Proxmox firewall (H37 = host mgmt plane). **k8s nodes (100-102,110-113,120) are explicitly EXCLUDED** — their traffic security is owned by Cilium (H3 NetPol + M66 WireGuard) + UDM zones/L3 ACLs (M56/M52); a PVE VM firewall there is redundant and risky (must hand-maintain 6443/etcd/kubelet/VXLAN/BGP/MetalLB allows; any gap breaks the cluster). **Standalone VMs** get per-VM default-deny-inbound: **gh-runner** (1003, high value — outbound-only runner → deny inbound except mgmt), **asterisk-sbc** (1004 — scope SIP/RTP inbound to Twilio ranges + LAN), **vpn-local** (1002 → WG udp/9820-9821 + mgmt), **dns-fallback** (1001 → :53 + mgmt), **devbox** (1005 → SSH/mgmt). All NICs currently `firewall=0`, so enabling is per-VM opt-in. Overlaps UDM north-south; value is defense-in-depth + intra-Trusted micro-seg (the broad `Trusted→Trusted` allow from M56). Needs per-VM service mapping. **Effort:** M.

### ⏳ M76. SSH to nodes/VMs via short-lived certs (Tailscale SSH / SSH CA)
- **Source:** zero-trust assessment 2026-06-17. Node/VM SSH uses a **long-lived key** (`id_ed25519_homelab`). **Do:** move to short-lived identity-bound SSH — **Tailscale SSH** (hosts already on the tailnet; gate via ACL + check mode) or an SSH CA (step-ca) issuing minutes-long certs. Pairs with **M71** under one "kill standing creds" theme. Spec in the assessment doc. **Effort:** M.

### ✅ M78. OneDrive (work) backup → NAS → S3 — superseded by [[M88]] (done 2026-06-20)
- **Source:** owner 2026-06-17. Mirror the GDrive pattern (`platform/kubernetes/rclone-gdrive/`): an **rclone** CronJob `rclone sync onedrive: /backup/Graham/OneDrive/` into the NAS `Backups` share → auto-S3'd by the existing `aws-s3-sync` `backups` share. New `rclone-onedrive` ns/manifests + a SOPS `rclone-config` secret holding the OneDrive OAuth token. **Auth: personal account** (used for work, not a locked corporate tenant) → standard `rclone authorize "onedrive"` OAuth works, no admin-consent issue. Owner runs that once (browser, on a machine with rclone) → token → SOPS secret → deploy. **Effort:** S (mirrors gdrive).

### 🟡 M79. iCloud Photos backup (priority) → NAS → S3 — run on the mini
- **Source:** owner 2026-06-17. Highest-priority iCloud item. Want **individual files (not the .photoslibrary container) + attached settings**. **Decision:** **`osxphotos`** (owner: icloudpd was tried years ago, never worked). Exports **originals + edited + XMP sidecars** (albums/keywords/faces/GPS/captions) as individual files → NAS `Backups` → S3. Mini signed into iCloud (`graham.m.smith@mac.com`).
- **🔑 Disk constraint (the crux):** osxphotos reads a **local** Photos library, but the mini has only **~11–40 GB free** — nowhere near a full library. **Solution: host the Photos library in an APFS sparsebundle on the NAS (SMB), mounted on the mini** (macOS sees a local APFS volume; bits live on the NAS) → "Download Originals" into it → `osxphotos export --update` (XMP sidecars) → individual files+sidecars → S3. The sparsebundle (working library) is **never** uploaded (not in the export dir); only the exported files are. **Caveat:** sparsebundle-over-network corruption risk if the link drops mid-write (Time-Machine model; acceptable — the lib is a cache of iCloud → corruption = rebuild, not data loss). **Robust alt:** external APFS SSD on the mini.
- **✅ Built 2026-06-18 (`infra/macos/mini/`):** `create-photos-sparsebundle.sh` (run — bundle exists at `/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle`, 2 TB sparse, attaches as `/Volumes/PhotosLib`); `photos-export.sh` (preflight `mount-nas.sh` → `hdiutil attach` → `osxphotos export --update --sidecar XMP --cleanup` → `/Volumes/Backups/Graham/iCloud/Photos`; exits 0 "not ready" until a `*.photoslibrary` exists); `net.wind.photos-export.plist` LaunchAgent (daily 22:00 PT — **authored, NOT loaded yet**). `osxphotos` 0.76.1 installed via **pipx** (NOT in brew core; works under Python 3.14). Full owner runbook in `infra/macos/mini/README.md`.
- **✅ Design simplified 2026-06-18 — NO new bucket/share.** Export target `/Volumes/Backups/Graham/iCloud/Photos` is a subtree of the **`Backups`** NAS share, which the **existing `s3-sync-backups` CronJob** (01:00 PT) already syncs to `archive.wind.etherport.net` (Glacier **Deep Archive**). Owner accepted Deep Archive's ~12 h retrieval for photos → **dropped** the earlier separate Glacier-Instant-Retrieval `photos` bucket plan (no TF bucket/IAM, no NFS export, no new s3-sync share — `Backups` is already NFS-exported to the node IPs and has no `Graham` exclude).
- **🟡 Owner setup IN PROGRESS (2026-06-18):** System Photo Library created inside the sparsebundle (`Photos Library (NAS).photoslibrary`), iCloud Photos on, catalog synced. Old `~/Pictures` library left untouched as fallback.
- **⚠️ iCloud background "Download Originals" stalls on the headless mini** (2026-06-18): catalog + thumbnails synced but original masters froze at **192/14,267** for hours (`cloudphotod` idle at 0% CPU, no progress, byte-identical over a 45 s sample) **even with Photos open**; `killall cloudphotod` didn't revive it (network/thermal/space all fine). **Fix: `photos-export.sh` now uses `osxphotos export --download-missing --use-photokit`** — fetches each missing original on demand via PhotoKit at export time (independent of the flaky background queue; fetched masters persist in the library on "Download Originals" mode → one-time download per photo, not per run). **Validated** (forced `--missing --download-missing` run: exported w/ XMP, error 0, library originals 192→196, no TCC prompt).
- **🟡 First bulk export reached 71%, then SMB instability + library corruption — ROOT CAUSE FOUND & FIXED** (2026-06-19): full export ran to **10,203/14,343** (~3.5 h), then the SMB mounts dropped repeatedly — including **`Personal-Drive` dropping while completely IDLE** on the 10G wired link, which force-quit Photos ("quit to prevent corruption") and left the sparsebundle's APFS journal dirty; after a reboot Photos errored "PhotosLib cannot be found." **Root cause: no `nsmb.conf` existed → macOS SMB *multichannel* was ON**, the classic cause of spontaneous idle SMB session resets against a NAS on a fast NIC (NOT write-load, sleep, or bandwidth — sleep was already disabled, link is 10G). **Fix (sudo-free, in git, self-healing on rebuild): `infra/macos/mini/nsmb.conf`** (`mc_on=no` + SMB1 off + `notify_off`), installed to `~/Library/Preferences/nsmb.conf` by `mount-nas.sh` before it mounts. **Validated** by checkpointing the library's 14 GB un-checkpointed WAL = a 14 GB sustained network write soak: **0 drops, 0 SMB reconnects** start→finish. **Library NOT corrupted** — after the WAL checkpoint, `PRAGMA integrity_check` = `ok`, 14,267 photos readable (the earlier "malformed" was purely the outstanding-WAL artifact). Two durability gaps also fixed in `mount-nas.sh`: it now (a) installs `nsmb.conf` and (b) **attaches the sparsebundle at login** (nothing did before → that's why PhotosLib didn't come back after reboot). Resume wrapper hardened: auto-attaches the bundle + `--cleanup` is now opt-in (`CLEANUP=1`; default OFF because the `.osxphotos_export.db` was lost in the corruption → cleanup without the ledger could delete+re-download). Full incident + lessons in [`session-log.md`](session-log.md) 2026-06-19.
- **🔴 ACTUAL ROOT CAUSE of all the SMB instability = NAS hardware (2026-06-19, owner-diagnosed via SSH to UNAS):** one of the two NVMe **SSD-cache** drives (`nvme0`) fell off the PCIe bus at ~11:04 (`controller is down, CSTS=0xffffffff`); Linux `md` kicked it from the cache RAID1 (`md4` degraded `[2/1]`), and `smbd`/`kcopyd`/`btrfs-transaction` went **D-state** (uninterruptible I/O wait) on the dead device → that is the "copy works ~10 s then hangs" symptom. Data array (RAID6 `md3`) + the surviving cache SSD healthy → **no data risk**. Timeline fits perfectly: NAS booted 06:17 (update), SSD dropped ~5 h later → the "stable ~5 h then degraded" pattern. So `mc_on=no` *was* a real improvement but the deeper instability was the dying SSD, not the client. **Resolution: owner rebooted the UNAS ~16:1x; `nvme0` re-probed clean, SMB stably healthy again** (verified by the watcher's 3× timeout-guarded reads). Lesson: when SMB degrades *progressively* (fine→flaky→EIO/hang over hours), suspect NAS-side storage/SMB health, not just the Mac.
- **🟢 Auto-resume on NAS recovery (2026-06-19):** built `~/Library/Logs/photos-export/auto-resume.sh` (not committed — one-off recovery orchestrator): polls a **timeout-guarded** 50 MB read off `/Volumes/PhotosLib` (a D-state hang ⇒ fail, not block), requires 3 consecutive healthy reads, then auto-runs `photos-export-resume.sh`. Fired at 16:24 when SMB recovered.
- **🟢 Export DB moved to LOCAL disk — the fix that finally let it complete:** osxphotos writes its export DB as the *final* step; on the blip-prone SMB share that write kept failing (rc=1, no clean completion → wrapper retried **~18×** even though files were exported). Pointed `--exportdb` at `~/Library/Application Support/osxphotos/graham-icloud-photos.db` + `--ramdb` (both `photos-export-resume.sh` and nightly `photos-export.sh`). First **clean `rc=0` completion** came at 22:08 (5h41m local-mode run). Also: `--download-missing --use-photokit` made opt-in (`DOWNLOAD_MISSING=1`); default = pure-LOCAL (no Photos.app/PhotoKit → no corruption dialogs/XPC wedges).
- **🟡 Clean completion REVEALED two issues (2026-06-19 22:08):** `Processed: 14343 photos, exported: 10420, skipped: 0, missing: 11538, error: 0`. (1) **~11,538 photo-versions' originals were never downloaded** — the PhotoKit run dropped at 71% before reaching them, so they are NOT yet backed up (only ~10,420 versions have local originals). (2) **Massive duplication on disk** — 55,745 files but **41,295 have `(N)` suffixes** collapsing to ~5,305 base names: the ~20 DB-less retries each re-assigned `(N)` numbers and re-exported the same photos under new names. Now fixable convergently because the **persistent local DB exists** (no more dup explosion).
- **🔴 DOWNLOAD_MISSING pass BLOCKED — recurring NAS SMB instability + PhotoKit wedge (overnight 2026-06-19→20):** the `DOWNLOAD_MISSING=1` pass hit two walls. (1) **PhotoKit XPC wedge:** even on healthy SMB, `osxphotos --use-photokit` ran ~1h27m with **0 downloads** then wedged on `CoreData: XPC: failed after 8 attempts` (`photolibraryd` serving the SMB library wedges after the day's crashes/force-quits). Restarting the Photos daemon stack (kill `photolibraryd`/`photoanalysisd`) is the intended fix (a fresh daemon is what let the first 5h run download 10,420). (2) **NAS SMB EIO returned ~02:35:** `Personal-Drive`/sparsebundle reads fast-fail with `[Errno 5]` (sparsebundle won't even attach) while **`Backups` stays healthy** — so it's a *Personal-Drive SMB-session wedge*, not the whole NAS (different from the nvme0 case which hung both). Possibly `nvme0` flapping again (owner: re-check the UNAS — is the cache SSD dropping intermittently? may need replacement) or just a session wedge. **`--download-missing` downloading was NEVER cleanly confirmed working post-recovery** (every attempt blocked by wedge or EIO before a clean download). **Action taken:** stopped thrashing the NAS; re-armed `~/Library/Logs/photos-export/auto-resume.sh` in **DOWNLOAD_MISSING mode** (gentle 5-min health-gated polling, 12 h window, force-remount on failure, fresh daemons before each export) → it will **auto-resume the download pass the moment the NAS is stably healthy**. Monitor watching for health/progress/completion.
- **⚠️ Backup completeness as of this pause:** ~10,420 photo-versions exported (originals downloaded), **~11,538 versions NOT yet backed up** (originals never downloaded), plus ~41k duplicate `(N)` files to clean. **Remaining work = the download-missing pass + cleanup**, gated on NAS-SMB stability (and confirming PhotoKit downloads actually work — if they don't even on a fresh daemon/healthy SMB, the fallback is iCloud re-auth in VNC or the non-photokit AppleScript download path).
- **Then (unchanged):** `CLEANUP=1` (`--dry-run` first) to delete the ~17k+ orphan duplicates → one canonical copy per photo.
- **Remaining (after download-missing + cleanup):** verify `missing: 0` + distinct count ≈ expected → enable the `net.wind.photos-export` timer → confirm `s3-sync-backups` ships `Graham/iCloud/Photos`. **Owner asked to report final exported count vs 14,267 + whether the timer is active.**
- **Caveats:** Apple **2FA session expires** every ~weeks→months → periodic interactive re-auth via VNC. Sleep disabled (`SleepDisabled`/`sleep 0`). Sparsebundle-on-SMB remains the architecture (owner is remote, no SSD option) — hardened SMB + login-time attach make it robust; **robust alt if it ever recurs: external APFS SSD on the mini**, or the sudo-only deeper levers (system-wide `/etc/nsmb.conf` + raised `net.smb.fs.kern_*_deadtimer` so a stall pauses I/O instead of erroring into APFS). **Effort:** M (tail + verify).

### ⏳ M80. iCloud Drive + Contacts + Messages backup → NAS → S3 — run on the mini
- **Source:** owner 2026-06-17 (lower priority than Photos). **Drive:** rclone `iclouddrive` backend (app-specific pw) OR the mini's native CloudDocs sync (`~/Library/Mobile Documents/com~apple~CloudDocs/`) → rsync — both yield individual files. **Contacts:** **`vdirsyncer`** over iCloud **CardDAV** (app-specific pw) → individual `.vcf` vCards (clean, no sign-in). **Messages:** back up `~/Library/Messages/` (`chat.db` + attachments) — requires the mini signed into iMessage; it's a SQLite DB + attachment files (restorable to a Mac), the only viable path (no API). All → NAS `Backups` share → S3. **Effort:** M.

### ✅ M81. Migrate Claude Code dev sessions mini → devbox (reboot-durable) — DONE 2026-06-18
- **Source:** owner 2026-06-18. The three persistent Claude Code dev sessions (`infra`, `cue`, `personal-web`) ran on the Mac mini, which reboots into a **FileVault lock** (no unattended auto-resume) and is being reserved for macOS-only iCloud work (M79/M80). Moved them to the always-on Linux **devbox** (`10.10.201.45`, tailnet `100.74.216.102`) — no FileVault gate, system `node`/`claude`/`tmux`/`git`, on tailnet+LAN, RC works (Claude Code v2.1.154+).
- ✅ **Done 2026-06-18:** all 3 migrated **with full history** (transcripts copied per project-path hash; each primed once via `claude --resume` to set `lastSessionId` so `--continue` follows). Reboot persistence via `infra/devbox/{resume-claude-sessions.sh,claude-sessions.service}` — systemd **user** unit + `loginctl enable-linger ubuntu`. Script self-heals (auto-clones a missing repo) + `cd`s explicitly (the `tmux -c` → `$HOME` fallback footgun). **Reboot test PASSED** (18:52): all 3 auto-resumed ~8s post-boot in the correct repo cwds. Marked the 3 operator shell scripts `0755` in git (`4b49e54`) — they were committed non-executable and only ran from a hand-`chmod`'d live copy (latent `ExecStart` failure on the next boot). Full narrative: [`session-log.md`](session-log.md) 2026-06-18. CLAUDE.md §3/§4 + `infra/devbox/README.md` updated.
- ⏳ **Follow-ups (not blocking):** **(a)** codify the live-but-undocumented bits into `playbooks/devbox.yml` — `kubectl` (v1.36.2, cluster-admin) + the `claude-sessions` systemd unit + linger (the playbook still ships the superseded single-session `claude-dev` launcher); **(b)** devbox lacks `terraform`/`~/.aws`/browser by design → route TF + headless-Chrome verification through CI or the mini, or install later; **(c)** the user's `~/.claude/.../memory/` files (not in git) didn't migrate — copy mini → devbox; **(d)** re-home the H3 cilium-audit `/loop` off the interactive thread (devbox systemd timer — it has kubectl).

## LOW

### ⏳ L24. Authenticate BGP sessions (MetalLB ↔ UDM)
- **Source:** zero-trust assessment 2026-06-17. The MetalLB↔UDM eBGP peers appear to run **without TCP-MD5/AO auth** → a rogue host on the peering VLAN could attempt route injection. Low real-world risk on a trusted fabric; cheap defense-in-depth: set a matching BGP password on both ends. Spec: [`zero-trust-assessment-2026-06-17.md`](zero-trust-assessment-2026-06-17.md). **Effort:** S.

### ⏳ L1. Proxmox HA cluster expansion
- Source: `archive/outstanding-work-2026-05-16.md` L1. Blocked on adding a 2nd PVE node.

### 🟡 L2. Regional VPN destroy doesn't drop the per-region Route53 record
- **Status 2026-05-24:** module-side fix shipped, workspace-side migration pending.
- **Done:** `infra/terraform/modules/regional-vpn/main.tf` now accepts `dns_zone_id` + `dns_record_name` variables; when both are set (and `use_elastic_ip = true`), creates an `aws_route53_record.vpn_endpoint` resource that destroy-cleans automatically. Output `dns_record_fqdn` exposes the created FQDN.
- **Still TODO:** the live `infra/terraform/aws-regional-vpn/` workspace doesn't use the modules/regional-vpn module — it's a self-contained set of resources that uses `associate_public_ip_address = true` (no EIP, so IP changes on every instance reboot, defeating the DNS-record point). Migrate that workspace to either (a) use the module with `use_elastic_ip = true` + `dns_zone_id`/`dns_record_name`, or (b) duplicate the EIP + Route53 record resources inline. (a) is cleaner but is a one-shot state-migration exercise (destroy + re-apply, accepting brief outage on the next regional spin-up).
- **Original entry:**


- **Source:** observed during M38 (Mumbai destroy 2026-05-23). After `terraform-regional-vpn.yml` action=destroy ran clean, the `vpn-travel.etherport.net. → 13.234.119.106` A record was still present (deleted by hand after). The regional-vpn module manages the EC2/VPC/SG side but doesn't own the public DNS record — that lives in the `route53` module as a separate resource keyed on the EIP. So destroy leaves a dangling record pointing at a freed-up Elastic IP.
- **Risk:** the next AWS customer to grab that EIP would receive traffic addressed to `vpn-travel.etherport.net` until the record's 300s TTL expires. Low real-world impact for a WireGuard endpoint (handshake fails without the right key) but still a leak.
- **Fix options:** (a) move the Route53 record into the regional-vpn module so the per-region apply/destroy owns it end-to-end; (b) wire a `data` reference + `null_resource` `destroy_provisioner` in the regional-vpn module to call `aws route53 change-resource-record-sets DELETE` on teardown; (c) accept it as a manual step in the resurrection runbook. (a) is cleanest.
- **Effort:** S.

### ⏳ L3. EIP → FQDN conversion debt (hardcoded ephemeral IP audit follow-up)
- **Source:** `docs/planning/archive/hardcoded-ephemeral-ip-audit-2026-05-23.md`. Several places still hardcode AWS Elastic IPs that *could* rotate if recreated: `vpn-use1` endpoint `35.169.37.16` in `platform/kubernetes/wireguard/03-deployment.yaml`, dns-aws `52.40.219.113` in M35 plan, etc. Convert each to a Route53 FQDN + DNS lookup at peer/config render time so an EIP swap doesn't require a code change.
- **Effort:** S per site, M overall.

### ⏳ L5. PVE BMC PEF / LAN alert destinations (cross-subnet PET trap)
- **Source:** M40 deliberately deferred. BMC sits on VLAN 200 (10.10.200.21); Alloy/Loki on VLAN 201 (10.10.201.73). For BMC PET traps to reach Alloy, the BMC needs to learn the gateway MAC for 10.10.200.1 — `ipmitool lan print 1` shows `Default Gateway MAC: 00:00:00:00:00:00` currently. Either populate the gateway MAC statically (one-shot ARP lookup + `ipmitool lan set 1 defgw mac <mac>`) or have the BMC do it via gratuitous ARP. Then enable PEF policy 1 with action="send to LAN destination 1" pointed at 10.10.201.73. Today we rely on BMC remote-syslog → Alloy which covers the same alerts.
- **Effort:** S.


### ✅ L15. Ship etcd snapshot timer logs to Loki — SUPERSEDED by M62 (2026-06-17)
- **Source:** M46 backup audit 2026-05-24. Timer-side failures were invisible (journald-only). The etcd-backup.yml playbook already forwards the snapshot journal to Loki (rsyslog → Alloy `10.10.201.73:514`), AND **M62 added the Prometheus metric + staleness/upload alerts** (`etcd_snapshot_last_run_timestamp`/`_s3_upload_success` → Pushgateway → `EtcdSnapshotStale`/`EtcdSnapshotS3UploadFailing`). Both fix options realized. Closed.

### ⏳ L14. AI advisor public approval URL — needs auth gate before advertise
- **Source:** Phase 2 wireup 2026-05-24. The `approve.etherport.net` Traefik IngressRoute is deployed but unadvertised (email links default to the Tailscale URL). HMAC-token-only auth on a public endpoint is too thin — anyone with email access can approve. Before flipping `APPROVAL_BASE_URL` to the public URL, add a zero-trust gate:
  - Option A: **Cloudflare Access** policy gating `*.wind.etherport.net` — requires Google SSO + email-domain restriction. ~30min setup; needs Cloudflare-as-DNS for the domain (currently Route53). Doable but moves DNS authority.
  - Option B: **Tailscale Funnel** — exposes a TS service publicly via TS-managed gate. No DNS change; gate is TS auth. Requires Funnel feature on the tailnet.
  - Option C (current): Stay TS-only; treat public Ingress as future infra.
- **Effort:** M.

### ⏳ L13. Phase 3 (autonomous execute) opt-in alerts
- **Source:** code shipped 2026-05-24 (`AI_PHASE3_ENABLED` env, default OFF). Per the phased rollout plan in `docs/runbooks/archive/ai-advisor-phase3-enable.md`: week 1 add `ai_remediation: "auto"` label to `NodeLocalDNSHighErrorRate` only; week 2 add `CoreDNSDown`; week 3 add `TechnitiumDNSDown` + `HomeAssistantDown`; expand 1/week as comfort builds. Never include CNPG / Ceph / kube-system alerts.
- **Effort:** Trivial per alert (one label addition). Spread across weeks for safety.


### ⏳ L7. Clean up debug Jobs in `backups` namespace
- **Source:** observed during M40 tidy 2026-05-23. Six failed pods from
  `unifi-backup-test`, `unifi-backup-test2`, `unifi-backup-test3` Jobs
  remain in the `backups` namespace (created 3.5h ago during M31
  debugging before the playbook landed). All have `status=Error`,
  contributing nothing — `kubectl get pods -A --field-selector
  status.phase!=Running,Succeeded` returns them as the only
  unhealthy pods cluster-wide. Cluster is otherwise green.
- **Fix:** `kubectl delete job/unifi-backup-test{,2,3} -n backups`
  (one-liner). Or wait for K8s' default Job TTL to expire.
- **Effort:** Trivial.

### ⏳ L6. Plex `ALLOWED_NETWORKS` parse error
- **Source:** surfaced 2026-05-23 by the new Plex logtail sidecar (M41). Plex repeatedly logs `ERROR - Error parsing allowedNetworks entry ' 10.10.201.0 24': Invalid argument`. The space-separated CIDR fragments suggest Plex is reading from its Web UI "LAN Networks" setting where the slash got stripped — likely an old config from before the env-var was set. The `ALLOWED_NETWORKS` env in `02-deployment.yaml` is correct (`10.10.201.0/24,...`); need to clear the Web UI value or re-sync. Library Settings → Network → LAN Networks → check/clear the value.
- **Effort:** Trivial (one UI click).

### ⏳ L16. k8s consistency nits
- Review 2026-06-10. Numbered-file convention (00-/01-) inconsistent across `platform/kubernetes/*`; Velero `backup-volumes-excludes` annotations present on some workloads, absent on most (cost — transient/media volumes get backed up); resource request:limit ratios vary wildly (ollama 12Gi limit vs 4Gi request). Standardize + lint. **Effort:** S each.

### ✅ L17. `setup-terminal.sh` hardening (2026-06-10)
- ✅ **Done:** `set -e` → `set -euo pipefail`. (The `brew install … || true` post-install `command -v` checks remain a nice-to-have but the strict-mode fix is the material one.)

### ⏳ L18. `optional: true` secret refs can start pods degraded
- Review 2026-06-10. e.g. `cue-api/01-deployment.yaml` — intentional for bootstrap, but a workload can run in a no-auth state; worth an alert on the empty-secret condition. **Effort:** S.

### ⏳ L19. Verify Telegram webhook auth (cross-repo)
- Review 2026-06-10. The one public POST (`/telegram/webhook`) relies on Telegram's secret-token header, validated in the separate `cue` app repo — not confirmable from infra. Verify the check exists (an unauthenticated webhook = abuse vector). **Effort:** S (verification).

### ✅ L21. `terraform-google` auth → GCP WIF — RESOLVED 2026-06-13
- Was: `terraform-google.yml` failed on an empty `GCP_SA_KEY` secret. **Resolved by the WIF cutover** (see Next-up checklist #7 / [`gcp-oidc-wif-l21.md`](gcp-oidc-wif-l21.md)) — the static-key path was replaced with GitHub→GCP Workload Identity Federation; no `GCP_SA_KEY` needed. CI dispatch = "No changes". Closed.

### ⏳ L20. Branch protection / CODEOWNERS (single-owner risk, accepted?)
- Review 2026-06-10. `main` has no enforceable branch protection (GitHub free plan on a private repo blocks required-reviews/checks) and no `CODEOWNERS`; the headless mini auto-pushes to `main`. Mitigate with a mandatory pre-push CI gate, or explicitly accept the single-owner risk. **Effort:** S (decision).

### ✅ L22. CI check that every `*.sops.yaml` decrypts (catch MAC/hand-edits) — DONE 2026-06-17
- **Source:** 2026-06-15 (surfaced during H33a). `platform/kubernetes/tailscale/01-oauth-secret.sops.yaml` had a **MAC mismatch** — its encrypted body had been hand-edited outside `sops` at some point (sops `lastmodified` 2026-04-12), so it no longer decrypted, yet nothing flagged it for ~2 months (the live secret kept working from the pre-corruption apply). Fixed by reconstructing `values.yaml` from the live `flux-system/tailscale-operator-oauth` secret + re-encrypting clean.
- ✅ **Done 2026-06-17:** added `.github/workflows/sops-decrypt-check.yml` — on every PR + push to main it `sops -d`s **every** `*.sops.yaml` in the tree (no path filter, so a long-corrupt file is caught too) via the pinned `setup-sops` action + `SOPS_AGE_KEY`. **CI run green.** A broken MAC / hand-edit now fails fast. (Left as a CI job, not a pre-commit hook, so it validates the whole tree centrally with the age key in a secret rather than on every dev machine.)

### ✅ L23. Clean up orphan `cnpg-manager` ServiceAccount/RBAC (post duplicate-operator removal) — DONE 2026-06-17
- **Source:** 2026-06-16. A **duplicate CNPG operator** (`cnpg-controller-manager`, from a pre-Helm raw-manifest install, not in git) was fighting the Helm operator (`cnpg-cloudnative-pg`) for the same leader-election lease → operator restart loop (37+29 restarts; the AI advisor's "stuck pod" alert). **Resolved** by deleting the orphan deployment; Helm operator is now uncontested leader, restarts stopped, DBs healthy throughout (see session-log 2026-06-16). **Residual (harmless):** the orphan's `ServiceAccount/cnpg-manager` in `cnpg-system` + cluster-scoped `cnpg-manager` ClusterRole + `cnpg-manager-rolebinding` ClusterRoleBinding remained — unused.
- ✅ **Done 2026-06-17:** verified orphaned (live operator `cnpg-cloudnative-pg` runs under SA `cnpg-cloudnative-pg`, not `cnpg-manager`; the CRB bound CR `cnpg-manager` → SA `cnpg-system/cnpg-manager` self-referentially; no pod used the SA), then deleted all three (`kubectl delete clusterrolebinding cnpg-manager-rolebinding` / `clusterrole cnpg-manager` / `sa cnpg-manager -n cnpg-system`). Operator still Running 1/1; `postgres-cluster` (3/3) + `cue-db` (1/1) healthy after. **Note:** the AI advisor correctly did NOT offer a remediation button — `cnpg-system` is on its hard denylist (advisory-only for critical stateful namespaces); expected behavior, documented in the session-log. These objects were never in git (raw-manifest install), so nothing to remove from the repo.

---
