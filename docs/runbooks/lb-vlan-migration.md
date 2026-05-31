# Runbook — migrate MetalLB VIPs to the dedicated LoadBalancers VLAN

**Tracker:** #9 / M59 · **Status:** foundation landed (VLAN + opt-in pool); per-service cutover staged below · **Risk:** per-service, tiered.

## What and why

MetalLB now advertises service VIPs to the UDM over **eBGP** (no L2/ARP — see
`platform/kubernetes/metallb/metallb-wind.yaml`). Because the VIPs are pure /32
BGP routes, they no longer need to live in the Servers/201 host subnet. This
migration moves them onto a dedicated **`LoadBalancers` VLAN 215 (10.10.215.0/24)**
so service front-ends are segmented from the K8s host network and can sit in
their own firewall zone.

### How the routing works (unchanged by the VLAN)
The K8s nodes **stay on VLAN 201**. They peer BGP to the UDM (`10.10.201.1`) and
advertise each VIP as a /32 with their own 201 IP as next-hop. The UDM installs
those /32s — more specific than the connected `10.10.215.0/24` — so traffic to a
`10.10.215.x` VIP routes to whichever node owns it. The `10.10.215.1` SVI has no
hosts; it exists only to define the subnet (for zone matching) and anchor the
range. **No node re-IP, no new NICs, no L2 on 215.**

## Foundation (DONE — safe/additive, no service impact)

| Artifact | What it does |
|---|---|
| `infra/terraform/unifi/networks.tf` → `unifi_network.loadbalancers` | Creates VLAN 215 `LoadBalancers` (10.10.215.0/24, DHCP off). `terraform apply` via the `terraform-unifi` workflow. |
| `platform/kubernetes/metallb/metallb-wind.yaml` → pool `lb-vlan` + `lb-vlan-bgp` | Opt-in pool `10.10.215.5` + `.70-.90`, `autoAssign: false`, advertised BGP-only. Allocates/advertises **nothing** until a service opts in. |

After the TF apply + Flux reconcile, **nothing has moved** — every existing VIP
is still on 201. The cutover below is per-service and reversible.

## Per-service cutover — order is lowest→highest blast radius

For each service: (1) update its downstream references **first**, (2) flip the
service to the new pool + IP, (3) verify, (4) only then move to the next. Each
re-IP triggers a new BGP /32 + withdraws the old one within seconds.

The pool flip on a Service is:
```yaml
metadata:
  annotations:
    metallb.universe.tf/address-pool: lb-vlan
    metallb.universe.tf/loadBalancerIPs: 10.10.215.<n>   # or spec.loadBalancerIP
```
(Several of these Services already pin `spec.loadBalancerIP` — change that field
+ add the `address-pool` annotation so MetalLB draws from `lb-vlan`.)

### 1. `traefik/traefik` — `.70 → 10.10.215.70` (LOW: single source)
The ingress VIP. Its only real reference is the **internal Technitium zone**.
- **Refs:** `platform/kubernetes/technitium/zones/wind.etherport.net.yaml` (many
  `value: 10.10.201.70` A-records → the wildcard/ingress hostnames).
- **Steps:** bump those A-records to `10.10.215.70` → Flux reconcile Technitium →
  flip the `traefik` Service to `lb-vlan`/`.70`. (External CF DNS already returns
  NXDOMAIN for these — internal-only, so no public DNS change.)
- **Verify:** `dig @10.10.201.5 traefik.wind.etherport.net` → `.215.70`; curl a
  hostname through the ingress; cert-manager TLSStore still serves the wildcard.

### 2. `dns/technitium-0` + `dns/technitium-1` — `.71/.72 → 10.10.215.71/.72` (LOW–MED)
Per-pod cluster/admin VIPs.
- **Refs (source of truth):** `platform/kubernetes/technitium/06-cluster-services.yaml`
  (`loadBalancerIP: 10.10.201.71` / `.72`); `dns-cluster.wind.etherport.net`
  `dns1`/`dns2` A-records.
- **Steps:** update both `loadBalancerIP`s + the `dns-cluster` zone A-records →
  reconcile. These drive inter-pod clustering + direct admin (`:5380`); confirm
  the cluster catalog still syncs after the flip.
- **Verify:** `dig @10.10.215.71 dns1.dns-cluster.wind.etherport.net`; Technitium
  cluster status shows both members healthy.

### 3. `monitoring/alloy-syslog` — `.73 → 10.10.215.73` (MED–HIGH: ~16 devices fan-in)
The syslog→Loki SIEM receiver. Many devices point at it; re-IP requires
reconfiguring **every syslog source**.
- **Refs:**
  - `clusters/wind/helm-releases/alloy.yaml` (`loadBalancerIP: 10.10.201.73`) — source of truth.
  - `infra/ansible/playbooks/udm-firewall.yml` (syslog allow target).
  - `infra/ansible/playbooks/ipmi-monitoring.yml` + `etcd-backup.yml` (rsyslog `target=`).
  - **Devices:** UDM, ×7 switches, ×7 APs (UniFi UI System Logging), PVE + BMC
    (ansible / BMC UI). Full list: `docs/runbooks/syslog-onboard-device.md`.
- **Steps:** update `alloy.yaml` + `udm-firewall.yml` + the two ansible playbooks
  → reconcile/apply → re-point every device per `syslog-onboard-device.md`. Keep
  the old `.73` answering until all sources are moved (or dual-advertise briefly).
- **Verify:** Loki shows fresh lines per `host` label from each source after cutover.

### 4. `dns/technitium` (primary DNS VIP) — `.5 → 10.10.215.5` (HIGHEST — gate on operator)
**Recommendation: do NOT move this autonomously. Either leave `.5` on 201
permanently, or migrate only with the operator watching.** Rationale:
- `10.10.201.5` is in `dhcp_dns` on **every** VLAN (`networks.tf`, 7 networks) and
  in `proxmox/standalone-vms/main.tf`. Every DHCP client caches it for the lease
  (`dhcp_lease = 86400` → up to 24h). A re-IP means clients keep querying the old
  `.5` until lease renewal, so the old `.5` must keep answering across that window.
- Safe path if pursued: (a) bring up `.215.5` alongside (pool allows both), point
  Technitium to serve on both, (b) update `dhcp_dns` + VM DNS to `.215.5`, (c) wait
  ≥ one full lease cycle (24h) with **both** live, (d) only then withdraw `.5`.
- The `.6` secondary (10.10.201.6) provides resilience during any DNS change — do
  not move `.5` and `.6` in the same window.
- `lb-vlan` reserves `10.10.215.5` so this stays an option without re-planning.

## Post-migration cleanup (after all desired services moved)
- Shrink/retire the `primary` pool range (`platform/kubernetes/metallb/metallb-wind.yaml`)
  to only what remains on 201 (likely just the DNS VIPs, if those stay).
- Update `README.md` (LoadBalancer/Ingress rows), `addons.yml` pool comment, and
  `platform/kubernetes/technitium/README.md` IP tables.
- Assign VLAN 215 to its firewall zone (pairs with **M56**, via the v2-API
  `udm-firewall.yml` pattern — the paultyng provider doesn't model zone membership).

## Rollback (any service)
Revert the Service's `loadBalancerIP`/`address-pool` back to the 201 value and
its downstream refs; MetalLB re-advertises the old /32 within seconds. The VLAN
215 network + `lb-vlan` pool can stay in place (harmless when unused).
