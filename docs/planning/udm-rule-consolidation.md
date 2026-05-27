# UDM Rule Consolidation & Modernization Plan

**Date:** 2026-05-27
**Status:** Proposal. No UDM changes have been made. Read-only research.
**Source material:** `docs/planning/udm-audit-2026-05-23.md`, `docs/planning/udm-config-drift-2026-05-17.md`, `docs/planning/firewall-zones-future-state.md`, `docs/planning/ubiquiti-config-as-code-2026-05-16.md`, `docs/runbooks/udm-network-app-modernization.md`, `infra/terraform/unifi/*`, `infra/ansible/playbooks/udm-firewall.yml`, `docs/runbooks/unifi-talk.md`, `docs/runbooks/twilio-talk.md`.

---

## TL;DR — Read this first

The UDM is roughly half-IaC today: VLANs, port forwards, static DHCP reservations and static routes live in `infra/terraform/unifi/` (paultyng provider, Phase 1 complete). Firewall zones, firewall groups, and policies are managed by `infra/ansible/playbooks/udm-firewall.yml` via direct v2 API calls. Most everything else (zones structure, IPS settings, DNS filtering, syslog destination, traffic rules, firmware channel, switch auto-upgrade) is UI-managed.

**Immediate consolidation wins from recent infra changes:**

1. **Delete `Wireguard Travel` port forward (UDP 9820 → 10.10.201.20)** — already `enabled = false` in `infra/terraform/unifi/port-forwards.tf:76-88`, kept as a documented placeholder. With regional VPN now site→AWS outbound, this is dead weight. Remove the TF block plus delete the corresponding UDM record. **No risk.**
2. **Confirm zero inbound port forwards exist for the 9 CF-Tunnel-migrated services.** Live `port-forwards.json` enumerated only 4 entries (Twilio-SIP, Twilio-Media-Signal, Wireguard Local, Wireguard Travel-disabled) — nothing exposes wiki/ha/plex/kopia/grafana/technitium/ollama/chat/approve, which is correct. Audit `infra/terraform/cloudflare/variables.tf` for the 3 stale `47.159.189.5` A records (lines 148, 156, 172) that may now be CF-tunnel CNAMEs instead — needs verification.
3. **Codify the new SIP 5061 TLS port forward in Terraform.** Doesn't exist yet in `infra/terraform/unifi/port-forwards.tf`. Just landed in the UI; needs an import block before the next plan run drifts. (See "Critical paths to NOT touch.")
4. **Audit `infra/terraform/cloudflare/variables.tf:148,156,172`** — 3 entries still pointing to `47.159.189.5` (UDM WAN). With CF Tunnel for 9 services, only `sip.wind.etherport.net` should legitimately be an A record to WAN IP now. The others should be CNAMEs to `<tunnel-id>.cfargotunnel.com` (pattern from `infra/terraform/cloudflare/alexa-service-token.tf:89`).

**Recommended start (~half a day):** items 1, 3, and 4 above, plus M32 (firmware channel `beta → release`) and M33 (rsyslog host = 10.10.201.73). All trivial, all reversible, all already documented.

**Defer:** the Phase-1-of-5 zone migration in `firewall-zones-future-state.md`. That's a 4–6 week project gated by Open Questions §6 (SimpliSafe egress dependency, Clients→Servers backup paths, Default/199 disposition, VPN WAN1 fate, L3-switch ACL story). Not a "consolidation" item — it's the next epic after this consolidation lands.

---

## 1. Discovery — what UDM config lives where today

### 1.1 Currently in code (durable)

| Resource | Location | Tool |
|---|---|---|
| VLANs (10 networks: Default/199, Mgmt/200, Servers/201, Clients/202, IoT/204, Security/205, Guest/206, vSAN/209, Ceph/210, Unifi/212, Inter-VLAN/4040) | `infra/terraform/unifi/networks.tf` | paultyng/unifi TF provider |
| Static routes (6: AWS Environment + WG Tunnel AWS + WG Client Tunnel × {UDM, L3-switch} variants) | `infra/terraform/unifi/routes.tf` | paultyng TF provider |
| Port forwards (4: Twilio-SIP, Twilio-Media-Signal, Wireguard Local, Wireguard Travel-disabled) | `infra/terraform/unifi/port-forwards.tf` | paultyng TF provider |
| Static DHCP reservations | `infra/terraform/unifi/reservations.tf` (320 lines) | paultyng TF provider |
| Firewall address-groups + port-groups | `infra/ansible/playbooks/udm-firewall.yml:46-62` (`udm_address_groups`, `udm_port_groups`) | Ansible v2 API |
| Firewall policies (zone-based, v2 API) | `infra/ansible/playbooks/udm-firewall.yml:73-95` (`udm_firewall_policies`) | Ansible v2 API |
| Dump/audit tool | `scripts/unifi/dump-state.sh` | curl + jq |
| Auth creds | 1P items `udm-tf`, `Unifi UDM API (Claude)`, `Windroute (tf-admin)`; soon `unifi-udm-api` (API key per M47) | 1Password |
| Backups | `platform/kubernetes/backups/unifi-backup` CronJob, daily 04:00 PT → `s3://infra.wind.etherport.net/unifi/` (M31 ✅) | K8s CronJob + SSH |

### 1.2 Still UI-managed (UDM-only source of truth)

From the live snapshots in `docs/planning/udm-audit-2026-05-23.md` and `docs/planning/udm-config-drift-2026-05-17.md`:

- **Zone structure** — only `IoT` exists as a custom zone; built-ins (Internal, External, Gateway, VPN, Hotspot, DMZ) carry every other network.
- **Firewall policies** — 114 total (110 predefined boilerplate, 4 user-authored: IoT-to-DNS, Allow-Wireguard, Allow-Twilio-SIP-6767, Allow-Twilio-Media-10000-60000). Only the 4 user-authored are in the Ansible playbook structurally; the playbook currently codifies just **one** (syslog UNVR+UNAS → Alloy UDP/514).
- **IPS / IDS / DNS Shield** — `ips_mode=ips`, ETPRO ruleset, 22 categories enabled, all per-VLAN `dns_filters` set to `none`. UI-only.
- **Traffic Rules** — none enumerated in any dump. UDM-side feature, UI-only.
- **WLANs** — 4 SSIDs, all UI-only.
- **Switch port profiles + per-port overrides** — captured in `portconf` + `stat/device` but not in TF.
- **L3-switch static routes + ACLs** — physically on the switch; not visible via the controller's `rest/routing` GET. Repeatedly flagged as unverified.
- **UDM controller TLS cert** — UI-uploaded today, reload via SSH. cert-manager wildcard exists; `platform/kubernetes/unifi-cert-sync/` is the K8s shim that pushes it.
- **Network Isolation flag per VLAN** — `network_isolation_enabled` not in paultyng schema (`networks.tf:24-26` comment confirms). Security/205 has it ON in live state but blank DHCP DNS — a known anomaly.
- **Firmware channel + per-device auto-upgrade flags** — `super_fwupdate.firmware_channel=beta` (should be `release`), `mgmt.auto_upgrade=true` site-wide.
- **rsyslog host** — `rsyslogd` enabled but `host` field empty. Receiver (`10.10.201.73:514` Alloy) is shipped; just needs the one UDM-side click (M33 pending).
- **SIP TLS (port 5061)** — just added in UI per recent session work. Live in UI; not yet in TF.

### 1.3 What changed recently that affects this audit

- **ALB decom** (saves $25/mo) — `*.wind.etherport.net` wildcard no longer fronts anything. The 3 stale A→`47.159.189.5` entries in `infra/terraform/cloudflare/variables.tf:148,156,172` plus the ALB references in `docs/architecture/aws-infrastructure.md` should be audited.
- **9 services moved to CF Tunnel + CF Access** — outbound `cloudflared` connections via `platform/kubernetes/cloudflared/02-deployment.yaml`. **No inbound port forwards needed for these.** Confirmed live state — no stale forwards exist for them.
- **SIP TLS 5061 inbound for Twilio Trunk just added** — port-forward target `sip.wind.etherport.net → UDM WAN 47.159.189.5`. **This is a new attack surface and a Talk dependency. Treat as load-bearing.** The Cloudflare TF block at `variables.tf:172` (which has `47.159.189.5`) is likely the `sip.wind.etherport.net` A record; needs confirmation.
- **Twilio Studio → Lambda Function URL** — no UDM concern (purely AWS-side).
- **9 services via CF Access** — incoming SIP (5061) is the **only** new inbound exposure.

---

## 2. Rule consolidation analysis — what can be removed

### 2.1 Definite removals

| Item | Source-of-truth file | Action | Risk |
|---|---|---|---|
| `Wireguard Travel` port forward (UDP 9820 → 10.10.201.20, enabled=false) | `infra/terraform/unifi/port-forwards.tf:76-93` | Remove TF resource + `import {}` block; delete UDM record `69f898115433d627dfc677c0` | None — currently disabled, regional VPN is now outbound site→AWS |
| LTE WAN interface (failover priority 4, never used) | UDM UI only — not in TF | Delete from UDM | None — `udm-config-drift-2026-05-17.md` line 30 confirmed retirement |
| Stale UDM fixed-IP reservations: `Filesync`, `Deepstack`, `Veeam`, `Security VM`, `OpenVPN local`, `OpenVPN aws`, `PBX`, `DataSync`, `TrueNAS` | `infra/terraform/unifi/reservations.tf` (some may already be removed; verify) | Remove from TF + UDM | Low — user confirmed retired in `udm-config-drift-2026-05-17.md:176` |
| Stale `peer_to_peer` PSK/SSID (old mesh-WiFi remnant, no AP uses it) | UDM UI only | Delete via UI or v2 API | None |
| Stale `mgmt.x_api_token` (if no integration references it) | UDM UI only | Trace usage; rotate or delete | Low if traced first |
| `WireGuard WAN 1` (192.168.3.0/24 UDM-side remote-user-vpn) — currently broken per `udm-config-drift-2026-05-17.md:29` | UDM UI only | Either fix or delete. Open question §6.4 of future-state doc. | Low if deleted; the active VPN path is in-cluster WG plus Tailscale |

### 2.2 Possible / needs verification

| Item | Why it might be removable | Verification needed |
|---|---|---|
| 3 stale A records `47.159.189.5` in `infra/terraform/cloudflare/variables.tf:148, 156, 172` | With CF Tunnel handling 9 services, these may be old ALB-era A records | Read `variables.tf` to identify which hostnames; cross-reference against the 9 services migrated to CF Tunnel + sip.wind.etherport.net |
| Firewall group `AWS Subnet` (`10.10.250.0/28`) | No other config in repo references this subnet | Open question from `udm-config-drift-2026-05-17.md:197` — user uncertain. Probably safe to delete unless it's the canary for a future arrangement. |
| Default/199 DHCP scope (`.100-.254` active on a "legacy" VLAN) | Audit recommends narrowing to `.250-.254` or disabling | Open question §6.3 of future-state doc — needs user decision |
| Twilio port forwards target `10.10.199.1` (Default VLAN) | This is Talk's listen IP. Per `unifi-talk.md`, intentional. **Do not change.** | None — confirmed in runbook |
| Per-VLAN DHCP DNS `52.40.219.113` as 3rd entry (M35 pending) | Resilience improvement, not consolidation | Tracked separately as M35 |

### 2.3 Boilerplate to leave alone

- The 110 predefined firewall policies UniFi creates automatically (`predefined: true` flag). Do not touch — they include the DHCPv6/RA/SLAAC/RADIUS/portal-redirect allows on `External → Gateway` (13 entries) that keep WAN working.
- The "External → Internal: Block All Traffic" defaults that protect the LAN from inbound. The only exceptions are the 4 user-authored allow rules.

---

## 3. Modernization opportunities — what to adopt

| Feature | Status | Recommendation | Rationale |
|---|---|---|---|
| **Zone-based firewall (v10)** | Already migrated 2024-12-22 | Stay current. Expand from 1 custom zone (IoT) toward the 4-zone end-state in `firewall-zones-future-state.md`, but treat that as its own epic. | Already on it; the consolidation here is shrinking and tidying the User-authored set, not redesigning. |
| **Firewall groups (Network Objects + Port Groups)** | 5 groups live (3 IP, 2 port). Spec wants 13+5. | **Expand now as pure-additive PR.** Pre-creates the named objects for any future allow rules. | Audit §2.1; pre-flight item for the future-state migration anyway. Low risk, high payoff in rule readability. |
| **UniFi Network Application Integration API + API key auth** | Auth header migration scoped in `docs/runbooks/udm-network-app-modernization.md`. Tracked as M47. | **Do as the first cutover.** Replaces username/password + cookie/CSRF in `udm-firewall.yml`. Half-day. Already greenlit. | Better key rotation, no MFA prompts, durable for CI. Foundational for everything else. |
| **Zone groups (v10 collection feature)** | Not present (404) on the controller | **Skip** until ≥3 custom zones exist. | Not useful with 1 custom zone. |
| **eBGP peering (M18) + MetalLB BGP mode** | Not configured | **Defer.** Cleanest fix for the MetalLB ARP conflict alerts (M36) but bigger lift; not consolidation. | Independent track; revisit after zone migration. |
| **Identity Enterprise / 802.1X** | Off | **Skip.** Paid service ($199/yr) for marginal homelab benefit. | Audit §2.7. |
| **Geo-IP block (WAN inbound)** | Off (`usg_geo.ip_filtering.enabled=false`) | **Adopt.** Block CN/RU/KP/IR inbound. 5-min change. Cuts WAN scan noise without affecting real users. **Important:** verify Twilio Signal CIDRs (8 × /30 — see `unifi-talk.md:108`) and Cloudflare ingress IPs are not in blocked geos before applying. | Audit §2.8. |
| **DNS Shield / per-VLAN content filtering** | Off across all 15 networks | **Selective adopt** — `IoT(204)=malicious`, `Guest(206)=adult+malicious`, `Default(199)=malicious`. Leave Servers/Mgmt/Clients/vSAN/Unifi/Ceph at `none` so Technitium remains primary. | Audit §3.4. Second-layer filtering catches DoH/DoT bypass attempts. |
| **Honeypot decoys** | 5 decoys at `.99` on Default/Servers/Clients/vSAN/Unifi | **Keep + wire alerts.** Currently alerts only land in UniFi UI. | Audit §3.10. Pair with the M33 syslog work to surface in Grafana. |
| **NetFlow (UDP/2055)** | Off | **Adopt later (P2).** Combine with M33 syslog to feed flow telemetry into Grafana. ~1 hour. | Audit §3.10. Pure observability gain. |
| **Firmware channel** | `beta` (likely accidental) | **Adopt fix immediately.** M32 — one click `beta → release`. | Audit §3.7. |
| **Auto-upgrade fleet policy** | Site-wide ON; only UDM itself is opted-out | **Decide and apply uniformly** (M34). Probable intent: fleet-wide opt-out. | Audit §3.7. |
| **Remote syslog (`rsyslogd.host`)** | Enabled, empty destination | **Adopt immediately.** M33 — set host `10.10.201.73:514` via UI or v2 API. Receiver already shipped (M37). | Audit §3.6. |
| **Auto backup (UDM)** | Wired (M31) ✅ | Done. | — |
| **TLS inspection** | Off | **Stay off.** Breaks TLS pinning, privacy footgun. | Audit §2.8. |
| **Traffic Rules** (newer policy primitive) | Not used | **Skip for now.** Zone-based policies cover everything; Traffic Rules are a parallel UI for the same backend. | No win for current footprint. |
| **mDNS reflector** | Off all networks | **Document the intentional off-state.** | Audit §2.9. |
| **IGMP snooping** | Off all networks | **Leave off.** No multicast workloads. | Audit §2.9. |
| **SmartQueues** | On WAN2, off WAN1 | **Document the asymmetry.** WAN1 doesn't saturate so SQM is dead weight; WAN2 (10/100) needs it. Intentional. | Audit §3.9. |

---

## 4. IaC migration plan — concrete file/playbook structure

### 4.1 Where each resource type should land

| Resource | Target tool | Target file (proposed) | Rationale |
|---|---|---|---|
| Networks (VLANs) | TF paultyng | `infra/terraform/unifi/networks.tf` (existing) | Stable schema, already there. |
| Port forwards (incl. new SIP 5061 TLS) | TF paultyng | `infra/terraform/unifi/port-forwards.tf` (existing) | Already there. Add new SIP-TLS block. |
| Static routes | TF paultyng | `infra/terraform/unifi/routes.tf` (existing) | Already there. |
| Static DHCP reservations | TF paultyng | `infra/terraform/unifi/reservations.tf` (existing) | Already there. |
| Firewall zones (custom zone CRUD) | Ansible v2 API | `infra/ansible/playbooks/udm-firewall.yml` (existing) | No TF coverage. Already the path. |
| Firewall groups (address-group + port-group) | Ansible v2 API | `infra/ansible/playbooks/udm-firewall.yml` (existing) — extend `udm_address_groups` + `udm_port_groups` lists | Already the path; add the 8 IP groups + 3 port groups from the future-state doc §2.4. |
| Firewall policies | Ansible v2 API | `infra/ansible/playbooks/udm-firewall.yml` (existing) — extend `udm_firewall_policies` list | Already the path; pull the 4 live user-authored rules into source. |
| IPS / DNS-shield / DPI / honeypot / NetFlow settings | Ansible v2 API (new playbook) | `infra/ansible/playbooks/udm-site-settings.yml` (NEW) | Site-level settings under `/proxy/network/api/s/{site}/set/setting/*`. Distinct from zone-firewall — own playbook. |
| Firmware channel + auto-upgrade flags | Ansible v2 API (new playbook) | `infra/ansible/playbooks/udm-firmware-policy.yml` (NEW) — small | Site-level setting `super_fwupdate.firmware_channel` + per-device `safe_for_autoupgrade`. Worth its own playbook for blast-radius reasons. |
| Remote syslog (`rsyslogd.host`) | Ansible v2 API | Roll into `udm-site-settings.yml` | Pure setting. |
| WLANs | TF paultyng (Phase 2) | `infra/terraform/unifi/wlans.tf` (NEW) | Provider supports `unifi_wlan`. Wrap in `lifecycle.prevent_destroy`. |
| Switch port profiles | TF paultyng (Phase 2) | `infra/terraform/unifi/port-profiles.tf` (NEW) | Provider supports. |
| Switch per-port overrides | TF paultyng (Phase 3) | `infra/terraform/unifi/switch-devices.tf` (NEW) | Provider supports `unifi_device`. |
| L3 switch ACLs | Ansible v2 API (new playbook) | `infra/ansible/playbooks/unifi-switch-acl.yml` (NEW) — gated CI approval | Per the original ubiquiti-config-as-code Phase 3. |
| UDM controller TLS cert | Already in `platform/kubernetes/unifi-cert-sync/` (CronJob) | No change | Already durable. |
| Talk / SIP trunk config | DEFERRED (M51) | No file — runbook is source-of-truth | No public API yet. |

### 4.2 Auth modernization (M47) is the keystone

Before any new playbook lands, swap `udm-firewall.yml` auth from username/password to `X-API-Key: {{ udm_api_key }}` per `docs/runbooks/udm-network-app-modernization.md` §"Auth migration". Every new playbook should use the API-key header pattern from day one — never the cookie/CSRF dance. This:

- Makes the playbooks GH-Actions-friendly (`UNIFI_UDM_API_KEY` secret).
- Eliminates the brittle `set_cookie` / `x_updated_csrf_token` extraction.
- Pre-positions for the moment Ubiquiti's Integration API v1 stabilizes write scope (probably late-2026 per their roadmap).

The four endpoint paths stay legacy (zones `/v2/api`, groups `/api/s/.../rest/firewallgroup`, policies `/v2/api/.../firewall-policies`) — just with the new header.

### 4.3 New playbook file structure (sketch)

```
infra/ansible/playbooks/
  udm-firewall.yml             # existing — zones, groups, policies (extend, don't replace)
  udm-site-settings.yml        # NEW — IPS, DNS shield, DPI, syslog, honeypot, netflow, geo-ip
  udm-firmware-policy.yml      # NEW — firmware channel, per-device auto-upgrade
  unifi-switch-acl.yml         # NEW — L3 switch ACLs (Phase 3)
  templates/
    (none new — uri{} payloads inline as today)
```

Each new playbook follows the existing `udm-firewall.yml` pattern: `op item get unifi-udm-api --fields credential` → `X-API-Key` header → `uri{}` tasks with check/diff support → idempotent reconcile. Reuse the same `udm_base` + `udm_site` + `udm_validate_certs` vars.

### 4.4 Capture script extensions

`scripts/unifi/dump-state.sh` already dumps networks, port-forwards, users, firewall-groups, firewall-rules (legacy/empty), sites, routing, port-profiles, devices, firewall-policies. Add for these new playbooks:

- `GET /proxy/network/api/s/{site}/get/setting/ips` → `ips-settings.json`
- `GET /proxy/network/api/s/{site}/get/setting/rsyslogd` → `rsyslogd.json`
- `GET /proxy/network/api/s/{site}/get/setting/super_fwupdate` → `super-fwupdate.json`
- `GET /proxy/network/api/s/{site}/get/setting/usg` (includes geo-ip, upnp) → `usg-settings.json`
- `GET /proxy/network/v2/api/site/{site}/firewall/zone` → `firewall-zones.json` (zone IDs already implicit in policies dump; this would make them explicit)

All read-only.

---

## 5. Cutover order — sequenced steps with dependencies

The phases below are **consolidation + modernization**, not the future-state zone migration (which is its own 5-phase epic in `firewall-zones-future-state.md`). Lowest-risk first.

### Phase A — Cleanup + trivial fixes (half a day, no maintenance window needed)

A0. **Modernize auth (M47) in `udm-firewall.yml`.** Half day. Verify `--check --diff` returns clean against live UDM with `X-API-Key` header only.
A1. Add **new Twilio SIP-TLS 5061 port forward** as a TF resource in `infra/terraform/unifi/port-forwards.tf` (with `import {}` from the UDM record's `_id`). Document in `docs/runbooks/twilio-talk.md` (already exists per grep) as the new authoritative ingress.
A2. Delete **`unifi_port_forward.wireguard_travel`** block from `port-forwards.tf` (+ delete UDM record).
A3. Delete **LTE WAN** interface in the UDM UI.
A4. Audit **3 stale `47.159.189.5` A records in `infra/terraform/cloudflare/variables.tf`** (lines 148/156/172). Identify which correspond to CF-Tunnel-migrated services and convert to CNAMEs to `<tunnel-id>.cfargotunnel.com` (pattern from `alexa-service-token.tf:89`). Keep the one for `sip.wind.etherport.net`.
A5. **Firmware channel** `beta → release` (M32, UI or `super_fwupdate` setting).
A6. **Auto-upgrade decision** (M34) — flip site-wide off or per-device off depending on what H23 intended.
A7. **rsyslog host** `10.10.201.73:514` (M33). One UDM API PUT or UI click.
A8. **Network Isolation on Security/205 + DNS DHCP** — decide and document one way or the other (audit P1 #6).
A9. **Geo-IP block** for CN/RU/KP/IR inbound (audit P1 #8). Verify Twilio CIDRs not blocked.
A10. **Delete stale UDM reservations** (Filesync/Deepstack/Veeam/Security VM/OpenVPN/PBX/DataSync/TrueNAS).
A11. **Add `Internal → Hotspot: Block All`** zone policy (audit P2 #11). Closes the documented "Internal can reach guest" gap.

**Dependencies:** A0 first (everything else uses the new auth). A1 before any TF apply that touches `port-forwards.tf` (otherwise plan shows drift).

### Phase B — Firewall groups expansion (pure-additive, half a day)

B1. Extend `udm-firewall.yml` `udm_address_groups` with the 8 missing IP groups from `firewall-zones-future-state.md:90`: `Management-Network`, `Servers-Network`, `Client-Network`, `IoT-Network`, `Security-Network`, `vSAN-Network`, `Ceph-Network`, `Unifi-Network`, `Home-Assistant`, `Router-Gateway`, `AWS-Networks`.
B2. Extend `udm_port_groups` with `NTP-Port`, `HomeAssistant-Port`, `UniFi-Adoption-Ports`.
B3. Apply via `ansible-playbook playbooks/udm-firewall.yml`. Verify in UDM UI all groups present.

**No rules use them yet — purely populating the named-object library.** Pre-flight for any future zone migration; also lets B4 happen.

B4. **Pull the 4 live user-authored policies into source** (`udm_firewall_policies`):
- `Allow IoT to DNS` (already a candidate from playbook docs)
- `Allow-Wireguard` (External UDP → 10.10.201.20:9821, inbound)
- `Allow-Twilio-SIP-6767` (External UDP from Twilio Signal IPs → Gateway:6767)
- `Allow-Twilio-Media-10000-60000` (External UDP from Twilio Media IPs → Gateway:10000-60000)
- **NEW:** `Allow-Twilio-SIP-TLS-5061` (External TCP from Twilio Signal IPs → Gateway:5061) — codify the new TLS-trunk rule.

These already exist live. The playbook is idempotent — first apply should be a no-op confirmation.

### Phase C — Site-settings playbook (half a day)

C1. Author `infra/ansible/playbooks/udm-site-settings.yml` (new). First scope: rsyslog host, IPS suppression list, honeypot enable, geo-ip block list, per-VLAN `dns_filters`, NetFlow enable.
C2. Move the changes from Phase A (A7, A9 in particular) into source so they re-converge on every apply.

### Phase D — Firmware policy playbook (half a day)

D1. Author `infra/ansible/playbooks/udm-firmware-policy.yml`. Scope: `super_fwupdate.firmware_channel` + `mgmt.auto_upgrade` site flag + per-device `safe_for_autoupgrade`. Idempotent.

### Phase E — Switch + WLAN coverage (1–2 days, P2)

E1. `infra/terraform/unifi/wlans.tf` — import 4 SSIDs with `lifecycle.prevent_destroy`.
E2. `infra/terraform/unifi/port-profiles.tf` — import 5 port profiles.
E3. `infra/terraform/unifi/switch-devices.tf` — import per-device port overrides for the L3 switch.

### Phase F — L3 switch ACLs (P3, gated, multi-day)

F1. SSH the L3 switch (or UI screenshot) to capture ACLs. Reverse-engineer current state.
F2. Author `infra/ansible/playbooks/unifi-switch-acl.yml` with manual-approval CI gate.
F3. Pre-flight: out-of-band serial/console verified before any apply.

**Phase F prerequisites:** UDM backup + restore tested (M31 ✅), L3-switch ACL state captured offline first.

---

## 6. Risk assessment — critical paths to not touch without careful review

These are the production load-bearing flows. Any consolidation step that touches them needs explicit verification before/after.

### 6.1 Inbound SIP (just landed — highest sensitivity)

**Paths:**
- UDP 6767 (legacy) → `10.10.199.1` (UDM Default VLAN, Talk listens) — old plain-SIP
- UDP 10000-60000 → `10.10.199.1` (Talk RTP media)
- **NEW: TCP 5061 (TLS) → UDM WAN `47.159.189.5`** — Twilio Elastic SIP Trunk over TLS, just added
- DNS: `sip.wind.etherport.net A 47.159.189.5` (Cloudflare TF, `variables.tf:172`)

**Source-of-truth:** `docs/runbooks/twilio-talk.md`, `docs/runbooks/unifi-talk.md`, `infra/terraform/unifi/port-forwards.tf`.

**Do not break:** the External → Gateway allow rules for Twilio Signal IPs (8 × /30 CIDRs) and Twilio Media IPs (`168.86.128.0/18`). They're hard-coded in the firewall groups `Twilio Signal IPs` + `Twilio Media IPs`. If Geo-IP block is enabled in Phase A9, verify Twilio's Oregon and other US Twilio edges are NOT in the blocked geos.

**Specifically for SIP 5061 TLS:**
- Needs a new `udm_firewall_policies` entry for `Allow-Twilio-SIP-TLS-5061` (External TCP from `Twilio Signal IPs` → Gateway:5061). Codify before next reconcile.
- The corresponding port forward needs to exist in TF (`infra/terraform/unifi/port-forwards.tf`). If user added in UI without TF, next `terraform plan` will not see it (provider doesn't import unknown resources automatically). Add an `import {}` block referencing the UDM record `_id`.
- Coordinates with M17 (Twilio Talk: migrate SIP trunk UDP → TLS+sRTP). The TLS port forward is the prerequisite. Update M17 status / link.

### 6.2 Plex (10.10.201.x, special IP handling)

Per `docs/planning/outstanding-work.md:498`, Plex has known LAN-network allowedNetworks parsing issues. The `ALLOWED_NETWORKS=10.10.201.0/24,...` env var lives in `platform/kubernetes/plex/02-deployment.yaml`. Don't change VLAN 201's subnet, don't add NAT, don't move Plex to a new VLAN. Plex is now CF-Tunnel-fronted so no inbound port forward exists; **do not add one accidentally.**

### 6.3 Home Assistant (10.10.204.25 — IoT VLAN, Alexa service token)

`platform/kubernetes/home-automation/deployment.yaml` attaches HA via Multus. HA traffic flow:
- IoT VLAN (204) → DNS allow rule → Technitium (`.5/.6`) ✓ codified
- HA reaches IoT devices on same VLAN — no UDM hop
- HA reached via CF Tunnel (`ha.wind.etherport.net`) — outbound cloudflared
- Alexa service token → CF Tunnel via `infra/terraform/cloudflare/alexa-service-token.tf`

**Do not break:** the IoT-to-DNS allow rule (the only IoT → Internal allow that exists). Verify it survives any zone consolidation. Open question §6.4 of future-state doc (HA-VLAN traversal) is downstream of this consolidation.

### 6.4 DNS (Technitium @ `10.10.201.5`/`.6`)

The MetalLB VIP `.5` and the `.6` dns-fallback VM together provide DNS resolution for the LAN. Per-VLAN DHCP DNS is set to `.5/.6` on Mgmt/Servers/Clients/IoT/vSAN/Ceph/Unifi.

**Do not break:**
- MetalLB L2 advertisement on VLAN 201 (the speaker pod owning `.5`).
- The hardcoded `47.159.189.5/32 + 66.215.210.75/32` allow in AWS SG `sg-0079fee23ee54417a:22/tcp` and `:53/{tcp,udp}` (`dns-restrict-ip` Lambda keeps these in sync with `wan1`/`wan2.wind.etherport.net`).

The MetalLB IP-conflict alerts on `.5` and `.71` (M36) are an artifact of L2 ARP re-election, not a real conflict. **Workaround = excluded-IP list** on the Servers VLAN until BGP migration (M18).

### 6.5 Proxmox API + cluster lifecycle

`pve.wind.etherport.net = 10.10.200.41` (Management VLAN). Used by:
- `infra/terraform/proxmox/k8s-vms/main.tf` (TF provider talks to PVE API directly)
- `infra/ansible/playbooks/proxmox*.yml`
- Ansible inventory `infra/ansible/inventory/wind/inventory.ini`

Proxmox traffic from Servers/201 → Mgmt/200 currently rides the `Internal → Internal: Allow All` default. **If/when Phase 4 of the future-state zone migration runs**, this becomes an explicit `Trusted → Trusted` allow (since both move into the same zone). Out of scope for this consolidation epic but worth being aware.

### 6.6 Ceph (10.10.210.0/24)

Storage fabric, dedicated VLAN (H25 migration completed). L3-switch-routed — UDM never sees this traffic. Anything in this plan that doesn't touch L3-switch ACLs leaves Ceph alone. Phase F (L3-switch ACL codification) is the one phase where Ceph health needs continuous monitoring during apply.

### 6.7 WireGuard + regional VPN

- Local WG → port forward UDP/TCP 9821 → `10.10.201.20` (keepalived VIP). Codified in `port-forwards.tf:53`.
- Regional VPN: now site→AWS outbound. The disabled `Wireguard Travel` (9820) is the artifact to clean up.

Do not break the `Allow-Wireguard` policy (External UDP → 10.10.201.20:9821 inbound) — it's a user-authored policy. If Geo-IP block is added in Phase A9, ensure the WG endpoint reachability path is not affected (the connecting clients are roaming, so traveler IPs vary — should be fine, but watch for false positives on first apply).

---

## 7. Effort estimate — sized in half-days

| Phase | Effort | Risk | Maintenance window? | When to start |
|---|---|---|---|---|
| A — Cleanup + trivial fixes (incl. SIP 5061 codification) | 1 half-day | Low | No | **First** |
| B — Firewall groups expansion + codify 4 live policies | 1 half-day | Low | No | After A |
| C — Site-settings playbook | 1 half-day | Low | No (settings only) | After A |
| D — Firmware-policy playbook | 0.5 half-day | Low | No | Parallel with C |
| E — Switch + WLAN TF coverage | 2 half-days | Medium (WLAN changes affect clients) | Yes for WLAN apply | After B/C/D |
| F — L3 switch ACL codification | 4+ half-days | High | Yes | After E + ACL capture |

**Total: ~10 half-days (~5 days) to consolidate everything except L3-switch ACLs and the future-state zone migration.**

**Start here, in order:** A0 (auth modernization) → A1 (SIP 5061 in TF — load-bearing, needed before next plan) → A2/A3 (delete dead WG-travel + LTE) → A4 (Cloudflare A→CNAME audit) → A5/A6/A7 (firmware + auto-upgrade + syslog — three trivial UI/API touches).

That sequence is ~half a day and unblocks the rest while delivering the immediate consolidation wins from the recent ALB + CF Tunnel changes.

---

## 8. Open questions to confirm before execution

1. **SIP 5061 TLS port forward** — what's its UDM record `_id` (so we can author the `import {}` block)? Probably `scripts/unifi/dump-state.sh` re-run will surface it in `port-forwards.json`.
2. **Auto-upgrade scope (M34)** — UDM-only opted out today (H23 intent), or full fleet? Need user call before D1.
3. **WireGuard WAN1 (UDM-side 192.168.3.0/24) fate** — fix or delete? See `udm-config-drift-2026-05-17.md:29` "configured this as backup … but it's not working so we'll need to diagnose."
4. **Default/199 DHCP scope** — keep `.100-.254`, narrow to `.250-.254`, or delete? Same `udm-audit-2026-05-23.md` recommendation surfaces here.
5. **`AWS Subnet` firewall group `10.10.250.0/28`** — purpose unknown. Delete or document? `udm-config-drift-2026-05-17.md:120` flagged it.
6. **Cloudflare TF variables.tf lines 148/156/172** — which hostnames are these? Probably `wan1/wan2/sip.wind.etherport.net`. `sip` must stay as A→`47.159.189.5`; the other two should be reviewed too (the dns-restrict-ip Lambda already keeps `wan1`/`wan2.wind.etherport.net` Route53 records in sync — does Cloudflare hold a parallel record?).
7. **L3-switch ACL story** — Ansible playbook with manual-approval gate (Phase F path), or hand-managed forever? Affects whether future-state zone Phase 2/4 risk is bounded.

These should be answered before kicking off Phase E (WLAN/switch coverage) and absolutely before any future-state zone migration. Phases A–D can proceed regardless.

---

## Critical Files for Implementation

- `infra/ansible/playbooks/udm-firewall.yml` — extend with new groups + 4-or-5 live policies; first target for M47 auth modernization.
- `infra/terraform/unifi/port-forwards.tf` — add SIP 5061 TLS import block; delete `wireguard_travel`.
- `infra/terraform/cloudflare/variables.tf` — audit the 3 stale A→`47.159.189.5` records (lines 148, 156, 172) and convert non-SIP ones to CF Tunnel CNAMEs.
- `docs/planning/firewall-zones-future-state.md` — companion epic; this consolidation plan is a prerequisite for kicking off its Phase 1.
- `scripts/unifi/dump-state.sh` — extend with `ips-settings.json`, `rsyslogd.json`, `super-fwupdate.json`, `usg-settings.json`, `firewall-zones.json` captures so the new site-settings playbook has authoritative reference state.
