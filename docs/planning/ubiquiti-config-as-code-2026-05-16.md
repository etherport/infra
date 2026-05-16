# Ubiquiti / UniFi Config-as-Code Opportunity Survey

**Date:** 2026-05-16
**Scope:** UDM Pro ("Windroute"), L3 switch ("Switch Rack PoE"), UniFi APs, UniFi Protect NVR.
**Goal:** Inventory what is UI-managed today, map each item to a candidate tool, and rank by value/effort.

## 1. Current State

### Already in code

| Item | Where |
|---|---|
| DDNS for `wind.etherport.net` | `infra/terraform/aws/ddns-lambda/` + UDM dynamic DNS client (config still in UI but trivial) |
| WireGuard tunnel endpoint params (port 9820 forward target) | Documented in `infra/terraform/modules/regional-vpn/` and `platform/wireguard/README.md` — but the actual UDM port-forward rule lives in the UI |
| Static DNS for homelab hosts | `platform/kubernetes/technitium/zones/wind.etherport.net.yaml` (Technitium, not UDM) |
| Firewall zone *design* | `docs/architecture/firewall-zones.md` — design only, rules typed into UI by hand |

### Currently UI-managed (everything else)

VLAN definitions, DHCP scopes, inter-VLAN routes, zone-based firewall rules (post-v10), traffic rules, port forwards (incl. WG 9820, WG 9821), WLAN SSIDs, switch port profiles, switch port-to-VLAN bindings, the L3 switch's inter-VLAN ACLs (201/202/209), VPN clients, Protect/NVR settings, the UDM controller web-UI TLS cert, admin users, alerting, and controller backups.

## 2. Tooling Landscape (2026)

| Tool | Coverage | Notes |
|---|---|---|
| `paultyng/terraform-provider-unifi` | Networks/VLANs, WLANs, firewall rules+groups, port forwards, user groups, RADIUS profiles, port profiles, device port overrides, static routes, dynamic DNS | Most mature. Lags 1–2 minor versions behind UniFi Network app. **Does not** support the new v10 zone-based firewall yet (uses the legacy firewall API, which still works in parallel). |
| `ubiquiti-community/unifi-network-api` (Python) | Read+write via REST | Useful for one-off scripts / Ansible `uri` wrappers |
| Ansible `community.network` UniFi modules | Thin, mostly deprecated | Skip — call the REST API via `uri` instead |
| UniFi Site Manager API | Cloud-side device inventory/SSO | Not relevant for per-site config |
| `config.gateway.json` | EdgeOS legacy override | **Not supported on UDM Pro v10+** — UDM uses different config plane. Skip. |
| Direct REST (`/proxy/network/api/...`) via curl/`uri` | Everything UI does | Fallback for anything Terraform provider misses (zone firewall, Protect, controller cert upload) |
| L3 switch (UniFi switches): `terraform-provider-unifi` `device_settings` resource | Port profiles, VLAN assignments | ACLs on UniFi switches: only via REST/SSH; no first-class Terraform |

## 3. Per-Category Recommendation

| Category | Tool | Effort | Risk | Rec |
|---|---|---|---|---|
| VLAN/network definitions (10.10.200/201/202/204/205/209/212, 4040 transit) | `terraform-provider-unifi` `unifi_network` | M | Low — `terraform import` per network, then plan/apply no-ops | **Do (Phase 1)** |
| DHCP scopes (per VLAN) | Same resource — DHCP is a field on `unifi_network` | S (rolls in free) | Low | **Do (Phase 1)** |
| Static DNS overrides on UDM | Not supported by provider | M (REST) | Low | **Defer** — Technitium already authoritative; phase this out instead |
| Zone-based firewall rules (v10) | REST via Ansible `uri` (provider lags) | L | **Medium-High** — easy to lock yourself out; need OOB recovery | **Defer 6 mo**; re-evaluate when provider catches up. Until then keep `docs/architecture/firewall-zones.md` as source-of-truth. |
| Legacy firewall rules + groups (still active) | `unifi_firewall_rule`, `unifi_firewall_group` | M | Low if you import existing rules first | **Do (Phase 2)** — covers most rules even on v10 |
| Port forwards (WG 9820, 9821, etc.) | `unifi_port_forward` | S | Low | **Do (Phase 1)** — small, high value (currently a tribal-knowledge item) |
| WLAN SSIDs | `unifi_wlan` | S | Medium — wrong PSK/security = clients drop | **Do (Phase 2)** with `lifecycle.prevent_destroy` |
| Switch port profiles | `unifi_port_profile` | S | Low | **Do (Phase 2)** |
| Switch port-to-VLAN bindings (per-device overrides) | `unifi_device` + `port_override` | M | Medium — wrong port = device offline | **Do (Phase 3)** after profiles are in place |
| **L3 switch inter-VLAN ACLs (201↔202↔209)** | See §4 below | L | **High** — this is what routes vSAN/cluster traffic | **Do, carefully (Phase 3)** |
| **UDM controller web-UI TLS cert** | See §5 below | M | Low (cert load is idempotent + reversible) | **Do (Phase 2)** |
| WireGuard server config on UDM | Not in provider; UDM WG UI is fragile | L | High | **Not worth** — already replaced by in-cluster WG (`platform/kubernetes/wireguard/`); just leave UDM as port-forward |
| Protect NVR config | No public API | — | — | **Not worth** |
| Admin users / SSO | Not in provider | M | Medium | **Defer** — low churn |
| Alerting / push notifications | Not in provider | — | — | **Not worth** |
| Controller backups | UI cron → S3 via UniFi built-in | S | Low | **Do** — point existing UniFi auto-backup at the `homelab-backups` bucket already provisioned in `infra/terraform/aws/` |

## 4. L3 Switch ACLs in Code (user question A)

**Constraint:** UniFi switches expose ACLs only via the controller REST API; `terraform-provider-unifi` has no first-class ACL resource as of 2026-05.

**Recommended path:**
1. Capture current ACLs: `GET /proxy/network/api/s/default/rest/networkconf` and `GET /proxy/network/api/s/default/stat/device/<switch-mac>` — dump to YAML in `infra/ansible/inventory/group_vars/unifi/`.
2. Author an Ansible role `roles/unifi_switch_acl/` that posts the desired ACL set via `ansible.builtin.uri` against the controller, using check-mode diff against the GET response.
3. Wrap behind a CI job that requires manual approval (high-blast-radius — a bad rule kills vSAN).
4. **Always keep an out-of-band serial/console path** to the switch during rollouts.

Alternative if you want fully declarative: deploy `network-controller` + write a tiny Go shim using the same library `paultyng/terraform-provider-unifi` uses (`go-unifi`) and expose ACLs as a custom Terraform provider. ~2 days of work; only justified if ACL churn is frequent. **Not recommended** for current churn rate.

## 5. UDM Controller Web-UI TLS Cert (user question B)

cert-manager already issues `*.wind.etherport.net` for Kubernetes ingress. The same cert can be reused on the UDM.

**Mechanism:**
1. Add a cert-manager `Certificate` for `unifi.wind.etherport.net` (or reuse the wildcard) with a `secretTemplate` that fires a reload.
2. Sync the secret out of the cluster: deploy `kubernetes-replicator` or a small CronJob that `kubectl get secret -o json`s the cert and pushes it to the UDM via SSH:
   ```
   scp fullchain.pem root@10.10.200.1:/data/unifi-core/config/unifi-core.crt
   scp privkey.pem  root@10.10.200.1:/data/unifi-core/config/unifi-core.key
   ssh root@10.10.200.1 systemctl restart unifi-core
   ```
3. Trigger on cert-manager renewal (every ~60 days). Wrap as a Kubernetes `CronJob` running weekly; idempotent because cert hash is checked first.

Public tooling: `unifi-cert-sync` (community shell script) does exactly this and is fine as a starting point — wrap it in a CronJob with SSH key from SOPS.

**Risk:** Low. UDM falls back to self-signed if the cert is malformed; recovery is one `scp` away. Persists across UniFi OS updates as of v4.x (previously did not — verify after each major UniFi OS bump).

## 6. Phasing

- **Phase 1 (1 day):** Stand up `terraform-provider-unifi` in `infra/terraform/unifi/`, import VLANs + DHCP scopes + port forwards. Pure reflection — no behavior change. Credentials in SOPS.
- **Phase 2 (2–3 days):** Import legacy firewall rules, WLANs, port profiles. Add cert-sync CronJob for UDM web UI.
- **Phase 3 (3–5 days):** Per-device port overrides; Ansible role for L3 switch ACLs with manual-approval CI gate.
- **Deferred:** Zone-based firewall (revisit Q4 2026), static DNS (kill instead), admin users.

## 7. Out of Scope / Skip

WireGuard server config on UDM, Protect, alerting, EdgeOS `config.gateway.json` patterns.
