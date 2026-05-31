# Outstanding Work — Consolidated Priority List

Latest revision: 2026-05-29. Canonical filename `outstanding-work.md`
is stable; older dated snapshots live in `archive/`.

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

---

## Open items

_Completed items (C1–C3, H1–H28, and the many done M-items) moved to the full snapshot: `archive/outstanding-work-snapshot-2026-05-31.md` (grep there for history). This file now lists only open/in-progress/gated work._

## HIGH — production-readiness; 1–2 weeks

### 🟡 H3. NetworkPolicies + ResourceQuotas + PDBs (Phase 1 — audit-only)
- **Source:** `archive/outstanding-work-2026-05-16.md` H3; task #2 (in_progress)
- Phase 1: LimitRanges + audit-only CNPs + conservative quotas already deployed via `platform/kubernetes/policy-baseline/`. Phase 2/3 (enforcement) pending Hubble observation window.
- **Effort:** L for Phase 2+3 (observation + tuning).

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
- **Effort:** M (exporter + creds + ServiceMonitor + dashboards).

### ⏳ M56. Migrate Servers/201 to a dedicated `Trusted` UDM zone (from Internal)
- **Source:** 2026-05-30, during BGP Phase B. 201 was placed in **Internal** for the gateway flip (minimal blast radius). A dedicated `Trusted` zone is the better end-state now that 201 is UDM-routed — intentional least-privilege vs Internal's allow-all.
- **Why deferred (not atomic with Phase B):** a fresh custom zone **default-denies inter-zone**, and 201 hosts homelab-wide deps — DNS VIP `10.10.201.5` (every VLAN resolves here), the WG remote-access endpoint `.20` (External→201 port-fwd), Traefik ingress `.70`. A single missing rule = LAN-wide DNS outage / remote lockout. Also every existing `X↔Servers` policy (currently keyed to Internal) must be re-pointed to Trusted — needs a live UDM zone-matrix audit.
- **Pre-staged allow matrix** (apply atomically with the zone; console/iKVM ready):
  - `Trusted→External` (egress); **`External→Trusted` udp/9820-9821→.20 (WG — lockout risk)**
  - `Internal↔Trusted` (DNS .5, Traefik .70, syslog .73, clients↔services)
  - `IoT/204→Trusted` (DNS .5 + existing Servers↔IoT); `Infra/212→Trusted` (DNS .5, syslog .73); `Security/205→Trusted` (DNS .5)
  - `Trusted→IoT/204` (→Home Assistant); `Trusted→Internal/Infra` (Prometheus scrape 200/212, storage)
- **Effort:** M. UI / v2-API (not TF — paultyng gap). Do in a window; verify DNS from every VLAN + WG reconnect after.

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

### ⏳ M48. UNAS Pro — bring under IaC via new per-device API key
- **Source:** 2026-05-26 user spotted the new "Create API Key" option in the UNAS app. Today UNAS config is fully UI-managed.
- **Scope:**
  - User creates API key in UNAS app → Settings → API. Stored in 1P as `unifi-unas-api`.
  - Add `unas_api_key` to SOPS secrets.
  - Net-new Ansible playbook `infra/ansible/playbooks/udm-unas.yml`. Start with a low-risk resource (e.g., admin user list or share permission audit), expand as patterns settle.
  - Use case: durability for whatever's currently UI-only (share configs, retention, accounts, SMB/NFS exports).
- **Effort:** ~1 day for first playbook; subsequent resources faster.
- **Note:** UNAS is a recent Ubiquiti product; API docs evolving. Pin Network App version in safety-check if endpoints stabilize per major release.

### ⏳ M49. UniFi Protect — bring under IaC via new per-device API key
- **Source:** 2026-05-26 (same trigger as M48). New per-device API key feature.
- **Scope:** mirror M48 but for Protect. 1P item `unifi-protect-api`. Playbook `udm-protect.yml`. Resources to manage as IaC: camera config (resolution, bitrate, motion zones), retention policies, user permissions, NVR-level alert rules. Start with a single resource type.
- **Effort:** ~1 day initial.

### ⏳ M50. Audit + gap-fill UDM/UNAS/Protect IaC coverage
- **Source:** 2026-05-26 outflow of #63 work. After M47-M49 land, walk through every UI page on UDM Network app, UNAS, and Protect; enumerate every setting NOT yet IaC-managed.
- **Scope:**
  - Output: a `docs/runbooks/udm-iac-coverage.md` table — UI page × management state × (durable / UI-only / needs-IaC).
  - Triage to critical-for-rebuild vs. nice-to-have.
  - Land the critical gaps as additional playbook resources.
- **Effort:** 1-3 days depending on triage scope.
- **Dependency:** M47 done first.

### ⏳ M51. UniFi Talk IaC — DEFERRED pending public API
- **Source:** 2026-05-26 research during Twilio Talk #22 work. Investigated whether UniFi Talk 3rd-party SIP provider config can be managed as IaC; conclusion = no public API exists today, and reverse-engineering the `/proxy/talk/...` endpoints is feasible (1-2 days) but undocumented (Ubiquiti can change them silently on any upgrade).
- **Decision:** wait for Ubiquiti to ship a public Talk API. Track via the open community feature request. Until then, the SIP provider config in [twilio-talk.md](../runbooks/twilio-talk.md) is the source-of-truth (UI-managed, documented).
- **Trigger to revisit:** Ubiquiti announces Talk API support.
- **Effort when unblocked:** ~1 day to write the playbook.

### ⏳ M59. Dedicated UDM-routed LB VLAN for MetalLB VIPs (segmentation)
- **Source:** 2026-05-31 networking review (#9). Now that MetalLB is BGP-only, move the VIP pool off Servers/201 onto a dedicated VLAN — cleaner segmentation, no intra-201 ARP nuance.
- ✅ **Foundation landed 2026-05-31** (`8d18aad`): `unifi_network.loadbalancers` VLAN 215 / 10.10.215.0/24 created on the UDM (TF applied via CI); MetalLB `lb-vlan` opt-in pool (`autoAssign:false`, 10.10.215.5 + .70-.90) + `lb-vlan-bgp` advertisement deployed. Inert until a service opts in — no VIP has moved.
- ⏳ **Remaining — staged per-service cutover** (`docs/runbooks/lb-vlan-migration.md`), ordered by blast radius: traefik `.70` → technitium-0/1 `.71/.72` → alloy-syslog `.73` (≈16 syslog devices) → **DNS `.5` LAST, gated on operator** (in `dhcp_dns` on every VLAN + 24h leases). Each cutover re-points live traffic + downstream refs (DNS zone records, syslog targets), so best done watched, not blind-while-away.

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

### ⏳ L8. Delete stale `platform/kubernetes/monitoring/values.yaml`
- **Source:** consistency review 2026-05-24. The file is the legacy chart-values that was replaced by inline values inside `clusters/wind/helm-releases/monitoring.yaml`. It's not referenced from any `kustomization.yaml`, so Flux doesn't apply it. Source of confusion (e.g. the original H5 entry pointed at the wrong file). Safe to delete; commits since the migration use the HelmRelease inline values exclusively.
- **Effort:** Trivial.

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

### ⏳ L9. Delete legacy traefik files
- **Source:** consistency review 2026-05-24. `platform/kubernetes/traefik/{pvc-traefik-ceph.yaml,traefik-acme-fix.yaml}` are explicitly labeled "Legacy. Safe to remove." in the traefik README but still on disk. Drop them.
- **Effort:** Trivial.

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

---
