# UDM / network config drift audit — 2026-05-17

Compares live UDM state (extracted today via `scripts/unifi/dump-state.sh`) against
all network-config documentation + IaC sources in the repo. Use this as the
working list for UniFi-as-code Phase 1 prep — markup with answers / decisions
inline, and we'll sequence the fixes.

**Live data snapshot:** `/tmp/unifi-state/`
**Generated:** 2026-05-17 from main@cc0a314

---

## VLAN inventory: docs vs UDM

| VLAN | UDM `name` | UDM subnet | Docs say (firewall-zones.md / network.md) | Discrepancy? |
|------|------------|-----------|-------------------------------------------|--------------|
| (untagged) | Default | 10.10.199.1/24 | "VLAN 1 / Default 10.10.199.0/24" | **YES** — UDM has `vlan: null` (untagged native); docs call it "VLAN 1". Not actually tagged. |
| 200 | Management | 10.10.200.1/24 | VLAN 200 Management 10.10.200.0/24 | Match |
| 201 | Servers | 10.10.201.1/24 | VLAN 201 Servers 10.10.201.0/24 | Match |
| 202 | Clients | 10.10.202.1/24 | VLAN 202 Clients 10.10.202.0/24 | Match |
| 204 | IoT | 10.10.204.1/24 | VLAN 204 IoT 10.10.204.0/24 | Match |
| 205 | Security | 10.10.205.1/24 | VLAN 205 Security 10.10.205.0/24 | **Retirement candidate** — see next section |
| 206 | Guest | 10.10.206.1/24 | VLAN 206 Guest 10.10.206.0/24 | Match |
| 209 | vSAN | 10.10.209.1/24 | VLAN 209 vSAN 10.10.209.0/24 | Match |
| 212 | Unifi | 10.10.212.1/24 | VLAN 212 Unifi 10.10.212.0/24 | Match |
| 4040 | Inter-VLAN routing | 10.255.253.1/24 | VLAN 4040 Inter-VLAN 10.255.253.0/24 | Match |
| n/a | WireGuard WAN 1 | 192.168.3.1/24 (remote-user-vpn) | **Not documented anywhere** | **GAP** — undocumented remote-user-vpn pool used by UDM-side WG client(s) |
| n/a | LTE | wan | **Not documented** in `firewall-zones.md` (only mentions WAN1/WAN2) | **GAP** — third WAN exists; port-forwards target `wan/wan2/wan3` |

**Tailscale connector miscoding** (`platform/kubernetes/tailscale/connector/connector.yaml:26-32`): comment says "VLAN 192" for 10.10.192.0/24, "VLAN 200 = Servers", "VLAN 201 = Kubernetes", "VLAN 203 = Guest 10.10.203.0/24". All four are wrong vs. UDM truth:
- 10.10.192.0/19 is the homelab supernet, not a VLAN.
- VLAN 200 = Management (not Servers); 201 = Servers (not just K8s).
- VLAN 203 / 10.10.203.0/24 does not exist on the UDM at all. Guest is VLAN 206.

---

## VLAN 205 (retirement candidate): where it's referenced

The user has stated VLAN 205 is being retired (cams moved to VLAN 212). Every
file below needs an update or removal as part of the retirement.

| File:line | What it says | Action needed |
|-----------|--------------|---------------|
| `docs/architecture/firewall-zones.md:28,51,82,95,125,138,159,177,205,215-221,288,294,333,364` | Security zone, NVR rules, "disable network isolation", explicit allow rules. | Rewrite zone-firewall doc after retirement; remove the dedicated Security zone and its NVR allow rules. |
| `docs/architecture/network.md:20` | Lists 205 as Multus parent ("security") in current configuration | Remove `vlan205-security` from Multus parent list once HA drops it. |
| `docs/reference/node-vlan-setup.md:25-27,44` | Calls out `enp6s21 → VLAN 205 → 10.10.205.0/24` on every K8s node | Update; remove `enp6s21` row. |
| `docs/runbooks/vlan-interfaces-netplan.md:75` | Smoke test pings `10.10.205.1` | Drop ping target. |
| `docs/planning/long-term-stability-review-2026-05-12.md:20,34,47,55` | Lists VLAN 205 macvlan attach on HA pod, vNICs | Historical context — annotate as superseded. |
| `docs/planning/archive/K8S-W3-DEPLOYMENT-PLAN.md:159-219` | systemd-networkd snippets for `10.10.205.53` / `10.10.205.60` | Archived — leave but tag retired. |
| `docs/planning/doc-drift-2026-05-16.md:101` | Notes 202/204/205 multi-VLAN reachability | Update once 205 retired. |
| `platform/kubernetes/multus/README.md:56-91` | NAD list, example annotations | Delete `vlan205-security`. |
| `platform/kubernetes/multus/network-attachment-definitions/vlan205-security.yaml` | Live NAD on cluster | Delete this manifest. |
| `platform/kubernetes/home-automation/deployment.yaml:32-37` | HA pod attaches `vlan205-security` with IP `10.10.205.25` | Remove this annotation block. |
| `infra/terraform/proxmox/k8s-vms/main.tf:138-142, 229-233, 341-345` | Every K8s VM (CP, worker, GPU) provisions a `vlan_id = 205` virtio NIC | Remove the 4th `network_device` block — otherwise rebuilds re-attach 205. |
| `infra/ansible/playbooks/k8s-node-fixes.yml:50,53` | Netplan brings `enp6s21` UP for VLAN 205 | Remove the `enp6s21` stanza. |
| `infra/packer/ubuntu-cloud-init/ubuntu-2404.pkr.hcl` (referenced by `multus/README.md:98`) | Packer bakes `/etc/netplan/51-vlan-interfaces.yaml` with VLAN 205 | Rebuild template VM 9001 after removal. |
| `infra/ansible/KUBESPRAY_MIGRATION.md:275,299` | History — `vlan205-security` NAD | Annotate retired. |
| `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml:81` and `k8s-net-cilium.yml:217` | Refer to "VLAN 202/204/205" comment | Trim. |
| `scripts/unifi/dump-state.sh` does not yet dump VLAN-port-profile assignments; UDM-side switch port profiles that tag 205 are not in this snapshot. | See L3-switch capture gap below. |

UDM state still has `Security` network active with DHCP scope `.100-.254` — **not yet retired on the UDM**.

---

## Static IP assignments: drift between sources

Inventory source: `infra/ansible/inventory/wind/inventory.ini`. DNS source: `platform/kubernetes/technitium/zones/wind.etherport.net.yaml`. UDM reservations: `/tmp/unifi-state/users-fixed-ip.json`.

| Hostname | inventory.ini | UDM reservation | DNS A record | Action |
|----------|---------------|-----------------|--------------|--------|
| k8s-cp1 | 10.10.201.50 | **none** | 10.10.201.50 | **Add UDM reservation** — currently relies on dhcp scope `.100-.254`; .50 is outside scope so VM has a static cloud-init IP, but no MAC anchor exists |
| k8s-cp2 | 10.10.201.51 | **none** | (not in DNS) | Add UDM reservation; add DNS record |
| k8s-cp3 | 10.10.201.52 | **none** | (not in DNS) | Add UDM reservation; add DNS record |
| k8s-w1 | 10.10.201.53 | **none** | 10.10.201.51 (zone calls this "k8s-w1") | **DNS DRIFT** — zone says `k8s-w1=.51`, inventory+TF says `.53`; archived K8S-W3 plan changed worker IPs but DNS zone never updated |
| k8s-w2 | 10.10.201.54 | **none** | 10.10.201.52 (zone calls this "k8s-w2") | **DNS DRIFT** — zone says `.52`, real `.54` |
| k8s-w3 | 10.10.201.55 | **none** | 10.10.201.53 (zone calls this "k8s-w3") | **DNS DRIFT** — zone says `.53`, real `.55` |
| k8s-w4 | 10.10.201.56 | **none** | (not in DNS) | Add DNS record + UDM reservation |
| k8s-gpu1 | 10.10.201.60 | **none** | 10.10.201.60 | Add UDM reservation |
| dns-fallback | 10.10.201.6 | **none** | 10.10.201.6 | Add UDM reservation (cloud-init pins it but no DHCP anchor) |
| vpn-local | 10.10.201.15 | **none** | 10.10.201.15 | Add UDM reservation |
| gh-runner | 10.10.201.30 | **none** | (not in DNS) | Add DNS record + UDM reservation |
| pve | (FQDN) — actually 10.10.200.41 | **none** | 10.10.200.41 | Add UDM reservation |
| traefik VIP | n/a | n/a (MetalLB, not DHCP) | 10.10.201.70 | OK — inside MetalLB pool |
| Technitium DNS VIP | n/a | UDM has reservation `10.10.201.5` MAC `00:0c:29:c2:24:a6` (named "DNS 1") | 10.10.201.5 | **MAC stale** — MetalLB now owns .5; UDM reservation points at an old VM MAC (00:0c:29 = vmware). Either delete or update. |
| Hue Bridges (`.51`,`.52` on VLAN 204) | not in inventory | UDM has `10.10.204.51` `00:17:88:7a:1f:3f` and `10.10.204.52` `ec:b5:fa:34:ab:ef` | not in zone | OK on UDM; add to zone (`hue1`, `hue2`) for documentability |
| Sequoia NAS | not in inventory | UDM `10.10.209.10` MAC `e2:83:54:f9:17:57` | 10.10.209.10 | Match |
| Canon printer (`print`) | not in inventory | UDM `10.10.202.50` `f4:a9:97:ca:ca:a4` | 10.10.202.20 ("print") | **DNS DRIFT** — DNS says .20, UDM reservation is .50 |
| Workroom Mac Mini | not in inventory | UDM `10.10.202.101` | not in DNS | Optional add |
| Grahams-MBP-WiFi | not in inventory | UDM `10.10.202.110` | not in DNS | OK |
| UPS1/UPS2/PDU1/PDU2 | not in inventory | UDM `10.10.200.10/.11/.15/.16` | DNS `ups1..pdu2` all point at Traefik VIP `10.10.201.70`, comments mention real IPs | Match (comments correct) |
| UniFi Protect (`protect`) | not in inventory | not in UDM reservations | 10.10.212.10 | **Gap** — `protect` has no MAC anchor; relies on whatever Protect controller is doing |
| Various standalones (Crashplan .22, Deepstack .28, Veeam .21, Security .26, OpenVPN local .17 / aws .16, PBX .25, AWS DataSync .21, TrueNAS .20) | not in inventory or DNS | UDM reservations exist | not in zone | **Documentation gap** — physical infra hosts that aren't tracked anywhere in repo. Either add to zone+inventory or note as out-of-scope-of-IaC. |

---

## Port forwards: documented?

| Entry (UDM) | Documented? |
|-------------|-------------|
| Twilio-Media-Signal UDP 10000-60000 → 10.10.199.1, src=Twilio Media IPs `168.86.128.0/18` | **No** — only references to Twilio in repo are explanations of why WG uses 9820 (`platform/wireguard/README.md:168`, `infra/terraform/aws-regional-vpn/main.tf:115`). Forward target `10.10.199.1` is the **legacy Default VLAN gateway** — implies a Twilio/Asterisk box living on the Default VLAN. PBX UDM reservation is at `10.10.201.25` though — possible config rot. |
| Twilio-SIP UDP 6767 → 10.10.199.1 | **No** — same gap. Same suspicious 10.10.199.1 target. |
| Wireguard Local UDP+TCP 9821 → 10.10.201.20 | **Yes** — `platform/wireguard/README.md:164` |
| Wireguard Travel UDP 9820 → 10.10.201.20 (currently `enabled: false`) | **Partial** — `platform/wireguard/README.md:163` documents wg0/9820, but UDM rule is named "Wireguard Travel" and is **disabled** — repo docs assume it's active for regional VPN. **This is a real production gap** — Mumbai/eu-west-1 regional VPNs claim to be active in `docs/runbooks/regional-vpn-deployment.md:11` but the inbound port forward is off. |

---

## VPN/AWS routes: are they captured?

**Not captured by current dump.** The UDM `networks.json` covers VLANs, WANs, and one `remote-user-vpn` entry (WireGuard WAN 1, 192.168.3.0/24). It does **not** include:
- Static routes (e.g., `10.10.100.0/22 → 10.10.201.20` for AWS, or `10.255.255.0/29` for the WG tunnel).
- The L3 switch's static routes that `docs/architecture/firewall-zones.md:108-114` claims handle AWS routing.

Firewall group `AWS Subnet` (`10.10.250.0/28`) is a curious singleton — **no other config in the repo references 10.10.250.0/28**. The repo treats AWS as `10.10.100.0/22` (us-west-2), `10.10.112.0/24` (mumbai), `10.10.116.0/24` (bahrain), `10.10.120.0/24` (planned ireland). 10.10.250.0/28 is mystery — either stale from a previous arch or an out-of-band management subnet.

**Verdict:** Static routes are the single biggest config-as-code gap. Without dumping them, we cannot verify the cross-cloud topology claimed in `docs/architecture/firewall-zones.md`. Need to add API endpoint:
- `GET /proxy/network/api/s/default/rest/routing` — UniFi static routes
- `GET /proxy/network/api/s/default/rest/dhcpoption` — DHCP option sets (some routes ride here)

---

## L3 switch routes: capture gap

`docs/architecture/firewall-zones.md:38-62` claims the L3 switch routes VLAN 201/202/209 and holds the AWS+WG static routes. The current `dump-state.sh` only hits site-level `rest/*` endpoints — it never enumerates per-device config, so we cannot verify:
- Which VLANs are routed by L3 switch vs. UDM (Layer 3 interface assignments).
- L3-switch static routes.
- Switch port profiles / per-port VLAN bindings.
- L3-switch ACLs (the design doc lists `Deny-Clients-to-vSAN` etc. — none of these are captured anywhere).

**Recommendation (don't extend the script — for next session):**
1. `GET /proxy/network/api/s/default/stat/device` — full device-config payload (per-device routing, port overrides, ACL counters).
2. `GET /proxy/network/api/s/default/rest/routing` — site-wide static routes.
3. `GET /proxy/network/api/s/default/rest/portconf` — switch port profiles (VLAN bindings live here).
4. `GET /proxy/network/api/s/default/rest/dhcpoption` and `.../setting/usw` for switch-global settings (jumbo, STP).
5. After capture, fold into a `terraform import` plan for `unifi_port_profile` + a hand-rolled YAML inventory for switch ACLs (matches the Phase 3 recommendation in `docs/planning/ubiquiti-config-as-code-2026-05-16.md`).

Firewall rules dump (0 entries) is a real finding, not an empty file: it means **all firewall policy is now in v10 zone matrix**, which exposes via a different endpoint (`/proxy/network/api/s/default/rest/firewallpolicy` and `/firewallzone`). Without those, `docs/architecture/firewall-zones.md` is unverifiable.

---

## Documented but absent

- VLAN 1 ("Default") referenced 8x in `firewall-zones.md` — on UDM this is an **untagged native** network, not VLAN 1.
- VLAN 203 (Guest 10.10.203.0/24) — in `platform/kubernetes/tailscale/connector/connector.yaml:30` comment only; doesn't exist on UDM (Guest is 206).
- "VLAN 192" — same Tailscale comment treats 10.10.192.0/24 as a VLAN; that's the homelab supernet.
- L3-switch static routes for `10.10.100.0/22`, `10.255.255.0/29`, `10.254.0.0/24` — claimed in `firewall-zones.md:111-114` but not in any UDM dump (which is consistent because they should live on the switch, but they're also not in any repo file).
- Firewall rules per `firewall-zones.md` (Mgmt-to-Servers, Clients-to-Servers, IoT-to-DNS, NVR rules, Security-to-Internet block, etc.) — `firewall-rules.json` is empty. These rules are either UI-only in the zone-based firewall (which uses a different API path), or never deployed.

---

## Present but undocumented

- `WireGuard WAN 1` remote-user-vpn network (192.168.3.0/24).
- `LTE` failover WAN (the third interface — `wan3` is referenced by every port-forward).
- Firewall group `AWS Subnet` (`10.10.250.0/28`) — origin unknown.
- DHCP DNS: VLANs 200/201/202/204/209/212 all hand out `10.10.201.5/.6`. Default VLAN gives no DNS. Security VLAN explicitly gives `""` for both. Guest hands out `1.1.1.1/8.8.8.8`. None of this is in any repo doc.
- Default VLAN DHCP scope `.100-.254` is still active despite `firewall-zones.md` saying "should be empty" — and Twilio port forwards target `10.10.199.1` on this VLAN.
- 14 of the 22 UDM fixed-IP reservations have no presence in inventory or DNS (Filesync, Deepstack, Veeam, Security VM, OpenVPN local/aws, PBX, AWS DataSync, TrueNAS, Workroom Mac Mini, Grahams MBP, Canon, Hue bridges, the unnamed .204.55).

---

## Top 5 fixes to land (priority order)

1. **Reconcile K8s worker DNS records.** `platform/kubernetes/technitium/zones/wind.etherport.net.yaml` claims `k8s-w1=.51, k8s-w2=.52, k8s-w3=.53`; real cluster is `.53/.54/.55`. Add k8s-cp2/cp3/w4/gh-runner records. This is silent for now because cluster nodes resolve each other by `/etc/hosts` and the kubeconfig uses IPs — but DNS-based access from off-cluster (e.g. ssh) hits the wrong host.
2. **Add UDM DHCP reservations for every host in inventory.ini** (k8s-cp/w/gpu, dns-fallback, vpn-local, gh-runner, pve). All are statically configured via cloud-init today, but DHCP could hand `.50-.60` to a random new device since the scope `.100-.254` is the only protected band. Build a `terraform-provider-unifi` `unifi_user` block from the inventory.
3. **Disable or remove the disabled `Wireguard Travel` port forward (9820)**, OR re-enable and verify, then document it as authoritative. Today `regional-vpn-deployment.md` claims Mumbai is active but the inbound listener is off.
4. **Extend `dump-state.sh`** to grab `rest/routing`, `rest/portconf`, `stat/device`, `rest/firewallpolicy`, `rest/firewallzone`. Without these the zone-firewall design doc and the L3-switch routing claims are unverifiable, and the empty `firewall-rules.json` is misleading.
5. **Fix VLAN-labeling errors and stale comments**:
   - `platform/kubernetes/tailscale/connector/connector.yaml:26-32` — drop the wrong VLAN labels (203 doesn't exist; 200 is Management not Servers; 192 isn't a VLAN).
   - `docs/architecture/firewall-zones.md` — "VLAN 1 / Default" should be "Default (untagged)".
   - Investigate the `10.10.199.1` Twilio forward target vs. PBX reservation at `10.10.201.25` — these should converge.

---

## Mark up here (open questions for review)

- [ ] Is the legacy `10.10.199.1` Twilio target still serving traffic, or should those port-forwards be deleted?
- [ ] Is the `AWS Subnet` firewall group (`10.10.250.0/28`) still needed?
- [ ] Are Hue bridges + Sequoia + the unnamed device worth adding to DNS as named records?
- [ ] Should `Wireguard Travel` be re-enabled, or is regional VPN reachable through a different path now?
- [ ] Do you want to add the K8s VIPs to UDM reservations, or keep them MetalLB-only?
- [ ] Phase 2: add capture for static routes + port profiles + zone-firewall policies?
