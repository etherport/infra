# Outstanding Work — Consolidated Priority List

Latest revision: 2026-06-10 (full-repo review). Canonical filename
`outstanding-work.md` is stable; older dated snapshots live in `archive/`.

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
| 1 | **M18/M36 MetalLB BGP** ✅ **COMPLETE 2026-05-31** | Was: MetalLB L2 mode → UDM `.5`/`.71` IP-conflict alerts | **A** 209 NICs → **B** 201→UDM-routed → **C** UDM↔MetalLB eBGP (8/8 sessions, 5 VIP /32s via BGP/ECMP) → **D** L2Advertisement removed (`69a332b`) = **BGP-only**. VIPs verified reachable intra-201 (kube-proxy) + cross-VLAN (BGP); only raw ICMP-to-VIP stops (harmless). M36 root cause (ARP/MAC churn) gone — **confirm `.5`/`.71` conflict alerts don't re-fire over ~1 day**. Runbooks: bgp-phase-{a,b,c}. UDM BGP is UI-managed (no API) — durable via git FRR config + controller backup; recheck → M58. Trusted-zone for 201 → M56. |
| 2 | **M15-M17 Twilio Talk** | 911 addr / orphan DID / SIP UDP→TLS+sRTP | M15 (911) safety-first; M16 release DID; M17 encryption |
| 3 | **M53 CF token scoping** | account-scoped token shared infra↔personal-web | Mint zone-scoped tokens; also unblocks M54 |
| 4 | **M54 smithforsb redirect IaC** | CF Single Redirect is manual in dashboard | Codify in `personal-web/cloudflare-dns/smithforsb.tf` once M53 lands |
| 5 | **M48/M49/M50 UNAS+Protect IaC** | UI-only | Per-device API keys → Ansible playbooks + coverage audit |

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

---

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

### 🟡 H3. NetworkPolicies — NONE deployed (corrected 2026-06-10)
- **Source:** `archive/outstanding-work-2026-05-16.md` H3; task #2.
- **Reality check (2026-06-10):** despite prior notes, `platform/kubernetes/policy-baseline/` contains ONLY LimitRanges + ResourceQuotas. There are **zero** NetworkPolicy / CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy objects anywhere (verified by grep across `platform/` + `clusters/`), and Cilium `policyEnforcementMode` is unset (default allow-all). So every pod can reach every other pod + external host — a compromised workload (public-facing cue-api, plex) has unrestricted lateral movement to postgres/dns/wireguard/monitoring. The "audit-only CNPs already deployed" claim was wrong.
- **Plan:** (1) ship the audit-only CNPs that were claimed → observe via Hubble; (2) default-deny + per-tier allowlist; isolate `postgres`, `wireguard`, `cue` first. The deployed part (LimitRanges/ResourceQuotas) stays.
- **Effort:** L. **Largest internal-segmentation gap.**

### ⏳ H29. CI AWS auth → GitHub OIDC (retire 22 long-lived static keys)
- **Source:** review 2026-06-10. 22 workflows inject `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (GH secrets); **0** use OIDC (`role-to-assume`/`id-token: write` absent). Long-lived IAM keys in CI = classic exfil target, no expiry, manual rotation across many secrets.
- **Fix:** IAM OIDC provider for `token.actions.githubusercontent.com` + `gh-actions-terraform` role (trust scoped to `repo:sparked-diamond/infra:ref:refs/heads/main`); add `permissions: id-token: write` + `aws-actions/configure-aws-credentials` `role-to-assume`; delete static keys. Free, mechanical — **highest-ROI hardening**.
- **Effort:** M.

### 🟡 H30. Supply chain — SHA-pin Actions + digest-pin images
- **Source:** review 2026-06-10. **0** of 104 `uses:` were SHA-pinned; **0** of 22 image refs `@sha256`-pinned; in-house images pull `:main`; SOPS binary curl'd unverified in 3 workflows.
- ✅ **Done 2026-06-11 (safe/non-rolling):** added `helpers:pinGitHubActionDigests` to `renovate.json` (next Renovate run opens a reviewable PR SHA-pinning all actions); authored `.github/actions/setup-sops/action.yml` (pinned + **checksum-verified** SOPS install, sha256 `5488e32b…` from the official checksums).
- ⏳ **Deferred to supervised (rolls pods / can break CI):** wire the 3 workflows (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn`) to `setup-sops`; add `digestReflectionPolicy: Always` to the 8 Flux `ImagePolicy` objects (image-reflector is v1.0.4 — supports it; triggers manifest-rewrite + pod rolls); fix the **dangling `cue-api` `$imagepolicy` marker** (no matching ImagePolicy → cue floats on `:latest`); bring in-house images under Flux + re-enable their Renovate digest tracking.
- **Effort:** M remaining.

### ✅ H31. Redesign `claude-admin` (break-glass, broad-but-not-escalation) + full IAM audit — APPLIED 2026-06-11
- **Reframe (owner 2026-06-11):** keep `claude-admin` as a deliberate one-off/break-glass user **outside Terraform**, but **broad-but-safe**. Chosen design: `PowerUserAccess` (all services except IAM/Org) + `claude-admin-oneoff-roles` (create/manage IAM roles under the `claude-*` prefix, **boundary-delegated** so no role it makes can do IAM writes → no escalation) + the scoped `claude-admin-policy`.
- ✅ **IaC done 2026-06-11:** deleted `claude-admin-temp.json` (the `iam:*`/`DeleteUser`/`s3:DeleteBucket`-on-`*` escalation primitive — confirmed still attached live); scoped `claude-admin-policy.json` (`IAMOrphanCleanup` → `user/terraform-*`; dropped `secretsmanager` write on `*`); added `claude-oneoff-boundary.json` (PowerUser ceiling) + `claude-admin-oneoff-roles.json` (boundary-gated role mgmt). Full user audit (10 users) captured in the review doc.
- ✅ **APPLIED 2026-06-11** (VNC bundle as claude-admin): created `claude-oneoff-boundary` + `claude-admin-oneoff-roles`; attached `PowerUserAccess` + `claude-admin-oneoff-roles`; pushed scoped `claude-admin-policy` (v9); **detached `claude-admin-temp`**. Verified: attachments = policy + oneoff-roles + PowerUserAccess (no temp); de-escalation confirmed (claude-admin lost the broad `iam:GetPolicy`-on-`*` that only temp granted).
- ⏳ **One manual nit left:** delete the orphaned `claude-admin-temp` **policy object** via the `gs_admin` console (claude-admin can't, post-detach — DeletePolicy is `terraform-*`-scoped). Harmless meanwhile (detached = grants nothing).
- ⏳ **Audit follow-ups (from the 10-user sweep):** `kubernetes-s3-backup` has an odd inline `billing-access`; `terraform-homelab` has redundant direct+group grants (H29's OIDC role consolidates). Details in `aws-iam-review-2026-06-11.md`.

### ✅ H32. Scope auto-remediation RBAC — confined destructive verbs (2026-06-11)
- **Source:** review 2026-06-10. `platform/kubernetes/auto-remediation/rbac.yaml` grants the controller SA cluster-wide `pods: delete`, `pvc: patch,delete`, `cnpg clusters: patch,update`. The "never auto CNPG/Ceph/kube-system" rule is code/prompt-only (`AI_NAMESPACE_DENYLIST`), not RBAC.
- ✅ **Done 2026-06-11:** moved the irreversible verbs (`pvc:delete`, `cnpg:patch/update`, `velero:create`) out of the cluster-wide ClusterRole into per-namespace Roles (`postgres` + `velero`) in a NEW `platform/kubernetes/auto-remediation-rbac/` dir (no namespace transformer, so the Roles land correctly — the original `auto-remediation/` kustomization's `namespace:` transformer would have relocated them). Recoverable verbs (pod restart, scale, job cleanup, pvc *expand*) stay cluster-wide. **Verified before push:** new dir renders Roles in postgres/velero, full `kubectl kustomize clusters/wind` builds clean (382 resources, no Flux-freeze), ClusterRole now `pvc: get/list/patch` only. Closes "delete any PVC in any namespace" (incl. cnpg-system/rook-ceph).
- ⏳ **Remaining (optional, supervised):** full hard-denylist via a per-namespace allowlist for ALL mutating verbs (this change confined only the *irreversible* ones; pod-restart etc. stay cluster-wide).

### 🟡 H33. Secrets-rotation runbook + 2nd age recipient (single-key blast radius)
- **Source:** review 2026-06-10. One age recipient decrypts ALL secrets; the private half is replicated to **3 holders** (mini disk, GH `SOPS_AGE_KEY`, Flux `sops-age`) — that's the real blast radius. No re-key path existed.
- ✅ **Done 2026-06-11:** wrote `docs/runbooks/secrets-rotation.md` (blast-radius inventory, routine two-phase rotation, full "mini compromised → rotate everything" incident procedure incl. the 1P-managed vs hand-edited secret split).
- ⏳ **Remaining (needs a terminal — deferred from the unattended session):** (a) generate the offline backup age recipient + `sops updatekeys` re-key (the runbook's H33a — re-encrypts all 60 SOPS files; not run unattended since a botched re-key could break Flux decrypt); (b) FileVault on the mini; (c) optional per-domain recipient split.
- **Effort:** S remaining.

### ✅ H34. Narrow + log the `trusted-admin-clients → Management` firewall rule (2026-06-11)
- **Done:** rule narrowed from `protocol: all` → entire Management zone, to `protocol: tcp` + `Mgmt-Admin-Ports` (22/443/8006) + `mgmt-admin-hosts` address-group (PVE `10.10.200.41`), `logging: true`. Applied from the mini; old broad `(all)` policy deleted via API (the playbook is create-only, so narrowing = create-new + delete-old). **Verified:** admin ports 22/8006 connect, non-admin 8007/3128 time out (dropped). (ICMP to mgmt hosts still passes — a UniFi default, not this rule.)
- **Remaining nicety:** add switch mgmt-UI IPs to `mgmt-admin-hosts` if/when needed.

## MEDIUM — quality / hygiene

### ⏳ M5. Velero schedule kustomization ordering + ResourceQuota CR
- Source: `archive/outstanding-work-2026-05-16.md` M5.

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


### ⏳ M53. Mint zone-scoped CF API tokens (de-couple infra ↔ personal-web)
- **Source:** 2026-05-29. Both repos currently use the same account-scoped `cloudflare-tf-token` (1Password). It works across all zones, which is why personal-web TF applied locally before it had CI. Best practice: each repo gets a token scoped to ONLY its zones.
- **Scope:** (1) new CF token scoped to grahamsmith.net/smithforsb.com/stopthecastle.com (Zone:DNS:Edit + Zone:Read + the Single-Redirect/Ruleset perm needed for M54) → 1Password → update personal-web `CLOUDFLARE_API_TOKEN` secret. (2) optionally re-scope the infra token to etherport.net only.
- **Note:** the current account-scoped token reportedly can't manage CF Single Redirect rules — confirm whether that's a scope/permission gap; if so the new token must include the Ruleset edit permission (this is what blocks M54).
- **Effort:** S (dashboard token mint + secret update). Needs CF dashboard.
- **Ready-to-execute spec (prepared 2026-05-30 — only the CF-dashboard mint needs you):**
  - **Create token** — CF dashboard → My Profile → API Tokens → Create Token → *Custom token*:
    - Permissions: `Zone → Zone → Read`, `Zone → DNS → Edit`, `Zone → DNSSEC → Edit` (required by the `cloudflare_zone_dnssec` resources), `Zone → Dynamic Redirect → Edit` (covers the Single Redirect ruleset → also unblocks **M54**).
    - Zone Resources: *Include → Specific zone* ×3 — `grahamsmith.net`, `smithforsb.com`, `stopthecastle.com`. **Do NOT** include `etherport.net` or "All zones".
    - Optional hardening: Client-IP filter → gh-runner egress IP; set a TTL.
  - **Wire-in (targets verified 2026-05-30):** personal-web CI reads the token from GH secret **`CLOUDFLARE_API_TOKEN`** (`.github/workflows/terraform.yml:67`; provider auth via env var). Zone IDs are already separate `TF_VAR_*_ZONE_ID` secrets, so the token needs no name→ID lookup.
    1. `gh secret set CLOUDFLARE_API_TOKEN -R sparked-diamond/personal-web` (paste new token) + save to 1Password.
    2. `gh workflow run terraform.yml -R sparked-diamond/personal-web -f action=plan` → expect clean across all 3 zones incl. DNSSEC.
    3. Leave the infra/etherport token in place (still in use); re-scoping it (part 2) is optional/separate.
  - **Why not done autonomously:** CF token minting is dashboard-gated and no CF token is available locally (1Password locked this session) — this is the single step that requires you.

### ⏳ M54. Codify smithforsb.com redirect (CF Single Redirect) as IaC
- **Source:** 2026-05-29. `smithforsb.com` → `instagram.com/graham.m.smith` is currently a **manual CF Single Redirect rule** in the dashboard — the one non-IaC piece of personal-web. Comment in `personal-web/terraform/cloudflare-dns/smithforsb.tf` notes it's deferred "until token scope upgraded".
- **Blocked by:** M53 (the account-scoped token apparently lacks the Ruleset/Single-Redirect permission).
- **Scope:** add a `cloudflare_ruleset` (http_request_dynamic_redirect) resource in `smithforsb.tf`; import the existing rule or recreate. Verify the redirect still 301s after apply.
- **Effort:** S once M53 unblocks it.

### ⏳ M55. Add UniFi telemetry exporter (unifi-poller) for UDM/network metrics
- **Source:** 2026-05-30. UDM observability is logs-complete but metrics-thin. Syslog → Alloy → Loki works (UDM-Pro-Max actively shipping, verified). But Prometheus has NO full UniFi telemetry — only `probe_success` (blackbox reachability, fixed 2026-05-30) + `unifi_backup_*`. Missing: client counts, throughput, WAN, port/PoE, AP/client RSSI, per-device health.
- **Scope:** deploy unpoller (unifi-poller) as a Deployment scraping the UDM controller API → Prometheus `ServiceMonitor` (must carry label `release: monitoring`, per the probeSelector lesson) → Grafana dashboards. Needs a read-only UniFi local account + creds (SOPS secret). Keep the UI/API access internal (Tailscale-only constraint).
- ✅ **IaC staged 2026-05-31** (`376af86`): full `platform/kubernetes/unifi-poller/` (Deployment v2.15.3 + Service + ServiceMonitor `release: monitoring`), inert/unwired so no CrashLoop noise. **GATED on operator:** create UniFi View-Only local account → encrypt `01-secret.sops.yaml` → uncomment the dir in `clusters/wind/kustomization.yaml` + the secret in its kustomization. 3-step runbook + dashboard IDs in `platform/kubernetes/unifi-poller/README.md`.
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

### 🟡 M60. Secret-scanning in pre-commit + CI (gitleaks)
- Review 2026-06-10. Pre-commit only has `sops-encryption-check` (fires on `*.sops.yaml` names) — a secret pasted into a `.tf`/`.md`/values/mis-named yaml sails through. Repo is clean today but unguarded.
- ✅ **`gitleaks` pre-commit hook landed 2026-06-10.** Remaining: a CI gitleaks job on PRs (pre-commit only fires for those who run it). **Effort:** S.

### 🟡 M61. Expand pre-commit + Renovate coverage
- Review 2026-06-10. ✅ **Landed 2026-06-10:** `terraform_tflint` (+ minimal `.tflint.hcl`) + `shellcheck` pre-commit hooks. Remaining: `ansible-lint` (needs a baseline-noise pass first), Renovate `github-actions` + `terraform` (provider) datasources, and centralizing the SOPS version (hardcoded `v3.9.4` in 2 workflows + the ansible-runner Dockerfile) into a composite `setup-sops` action with checksum verify. **Effort:** S-M.

### ⏳ M62. etcd snapshots → offsite (S3) + freshness alert (supersedes L15)
- Review 2026-06-10. `etcd-backup.yml` writes local-disk only (14d); offsite only via Velero's `kube-system-daily` — the exact path that silently `PartiallyFailed` ≥4d recently. If a CP node is lost, its snapshots go with it. Push snapshots to S3 from the playbook + emit `etcd_snapshot_last_run_timestamp` (textfile collector) + a staleness alert. **Effort:** S.

### ⏳ M63. k8s manifest hardening sweep
- Review 2026-06-10. Per-workload gaps: (a) `cloudflared` ServiceMonitor missing `release: monitoring` label → metrics never scraped; (b) `rclone-gdrive` CronJob has NO securityContext (runs root); (c) no `startupProbe` on slow-boot workloads (technitium DNS, home-automation, wikijs, ollama) → restart risk mid-rollout; (d) no PDB for 2-replica `cloudflared`; (e) home-automation `privileged: true` → scope to explicit caps + device mounts. Small per-file fixes; template the hardened securityContext (cue-api/cloudflared already do it right). **Effort:** M (sweep).

### ⏳ M64. Image-pinning model — pick one and apply repo-wide
- Review 2026-06-10. Mixed: 18 manifests auto-update via Flux `$imagepolicy`, ~10 use hardcoded floating tags. Decide canonical (Flux ImagePolicy+digest everywhere, or pin-by-digest + manual bump) and apply; document which apps auto-update vs frozen. Ties to **H30**. **Effort:** M.

### ⏳ M65. Terraform consistency — version pins, DRY, hardcoded IDs
- Review 2026-06-10. (a) `required_version` ranges differ across stacks (`>= 1.0` … `>= 1.5.0`) while CI pins 1.14.3 — standardize to `>= 1.14`. (b) `unifi/networks.tf` repeats a 10-line `lifecycle.ignore_changes` block ×11 — extract to a `local`. (c) `aws/compute/main.tf` hardcodes VPC/subnet/SG IDs + the automation SSH pubkey (duplicated in 3 places) — source from module outputs / a shared var. (d) proxmox stacks hardcode the PVE endpoint ×3 → shared var. **Effort:** M.

### ⏳ M66. Cilium pod-to-pod encryption — decide
- Review 2026-06-10. `cilium_encryption_*` commented out (off). With BGP now spanning VLANs (wider trust boundary) + no NetworkPolicies (H3), east-west pod traffic (incl. postgres replication, WG key material) is cleartext + unrestricted. Either enable WireGuard-mode Cilium encryption or document the accepted risk. **Effort:** M (or doc-only).

### ⏳ M67. Reconcile dead/contradictory Velero alerting config
- Review 2026-06-10. `platform/kubernetes/backups/velero/values.yaml` sets `serviceMonitor.enabled: false` (dead — the live Flux release sets it true inline); `monitoring/06-backup-alerts.yaml` still says rules "stay dormant until the SM exists." A future edit could "fix" the wrong file + silently disable Velero alerting (the failure mode that hid the recent partial failure). Delete/reconcile the unused values.yaml + stale comment; confirm `VeleroBackupPartial` actually fires in-cluster. **Effort:** S.

### 🟡 M68. Documentation consolidation + accuracy pass
- Review 2026-06-10. ✅ **Landed 2026-06-10:** (a) staleness banners on the Route53 docs `ubiquiti-ddns.md` + `1PASSWORD-CLI.md` (+ fixed the dead `ooefsxjnvx4khtbh63tn5fr3pu` item ref, filled the real Terraform key ID, pointed to `SOPS-SETUP.md` as canonical); (b) archived `metallb-bgp-migration-2026-05-29.md` + `networking-prod-review-2026-05-31.md` (no non-archive `firewall-zones-future-state.md` exists). Remaining: (c) full merge of `1PASSWORD-CLI.md` into `SOPS-SETUP.md`; (d) BGP-phase index over `runbooks/bgp-phase-{a,b,c}.md`; (e) `docs/README.md` index gaps (setup/network/, terraform remote-state-backend, AI-advisor "archived but live" wording); (f) M14 ID-ambiguity footnote in `firewall-zones.md`. **Effort:** S remaining.

## LOW

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


### ⏳ L15. Ship etcd snapshot timer logs to Loki
- **Source:** M46 backup audit 2026-05-24. The Ansible-managed etcd snapshot systemd timer on each PVE control-plane node writes only to journald — never reaches Loki. Snapshots themselves are captured by Velero's `kube-system-daily` FS backup, but timer-side failures (disk full, snapshotter crash) are invisible.
- **Fix options:**
  - (a) Install `systemd-journal-upload` or rsyslog forwarder on the CP nodes pointing at `10.10.201.73:514` (existing Alloy syslog receiver). Same pattern as the PVE ipmi-monitoring playbook's rsyslog forwarder. Adds ~10 lines to `etcd-backup.yml` playbook.
  - (b) Add a Prometheus textfile collector emitting `etcd_snapshot_last_run_timestamp` after each snapshot; add a staleness alert. More aligned with how other backup workloads alert.
- **Effort:** S either way.

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

### ⏳ L20. Branch protection / CODEOWNERS (single-owner risk, accepted?)
- Review 2026-06-10. `main` has no enforceable branch protection (GitHub free plan on a private repo blocks required-reviews/checks) and no `CODEOWNERS`; the headless mini auto-pushes to `main`. Mitigate with a mandatory pre-push CI gate, or explicitly accept the single-owner risk. **Effort:** S (decision).

---
