# Runbook — UDM/UniFi manual hardening actions (console-only)

Network-hardening items that **can't be done via IaC** (the `paultyng/unifi` TF provider
+ `udm-firewall.yml` don't cover them) and need the UniFi console. Created 2026-06-24
from the network-hardening cleanup pass. Do these in one sitting; tick them off + ping the
agent to update the tracker (M103 / M104 / M47 follow-up / L24).

> UI paths are for UniFi Network ~10.x (UniFi OS). Labels shift slightly by version — the
> nav intent is stable. Controller: `https://10.10.200.1` (or `unifi.ui.com`).

---

## 1. Security/205 (SimpliSafe) — disable Network Isolation + set DHCP DNS  (M104)

**Why:** VLAN 205 has L2 Network Isolation **ON** + empty DHCP DNS → SimpliSafe gear can't
resolve via the LAN. Owner decision: **fix** (zone firewall is the enforcement layer, not L2 isolation).

1. **Settings → Networks → `Security`** (VLAN 205).
2. **Advanced** (toggle Manual) → find **Network Isolation** / **Isolate Network** → turn **OFF**.
3. Same network → **DHCP → DNS Server** → set **Manual** → `10.10.201.5`, `10.10.201.6`.
4. **Apply Changes.**
5. Verify: a SimpliSafe device gets a lease + can resolve (or just confirm no resolver errors).

> Zone segmentation is unchanged — the custom **Security** zone still default-blocks 205 → all
> other zones (only →External/→Gateway allowed). Isolation was redundant with the zone model.

---

## 2. Unused switch ports → Disabled  (M103 — do the EXPOSED switches first, #18)

**Why:** ~33 unused/down ports fleet-wide default to the **Default/199** network (Internal
trusted-transit zone). A device plugged into an open jack on a **physically-exposed** switch
gets a foothold. Confirmed: Default/199 has **0 active clients** — safe to lock these down.

**Create a reusable "Disabled" port profile (once):**
1. **Settings → Profiles → Ethernet/Switch Ports → Create New Profile.**
2. Name `Disabled`; set **Port Operation = Disabled** (or Native VLAN = none + all tagged off). Save.

**Apply to unused ports — prioritise the exposed switches:**
`Switch Driveway`, `Switch Access Road`, `Switch Outdoor Junction`, `Switch Chapel`, `ua-gate`
(then the rest: Rack PoE 12 down, Office 6, Workroom 4, etc.).
3. **UniFi Devices → <switch> → Ports** (or Port Manager).
4. Select each **down/unused** port → set profile to **Disabled** (or per-port **Operation: Disabled**).
5. Leave a known spare or two if you need a maintenance jack — but on the *outdoor* switches, disable **all** unused ports.

Current unused counts (2026-06-24): Driveway 0 · Access Road 2 · Outdoor Junction 3 · Chapel 4 · (verify live).

---

## 3. Per-port VLAN minimisation on exposed switches  (M103 / #18)

**Why:** so a *hijacked* active port (unplug a camera, plug in) lands in an already-isolated,
zoned VLAN — not a trusted network. This is the real blast-radius control (MAC filtering is spoofable).

For each **active** port on the exposed switches, set its native/access network to **only** what
that device needs:
- **Camera ports → `Security` (205)** (already zone-isolated).
- **Outdoor AP ports → only their SSID VLAN(s)** — not a trunk-all.
- **`ua-gate` (UniFi Access) → a dedicated Access/door VLAN**, isolated to the Access controller.

UniFi Devices → switch → port → **Native/Access Network** = the specific VLAN; tagged networks = only what's required.

---

## 4. 802.1X + MAC-Auth-Bypass (MAB) — project, not a quick toggle  (M103 / #18)

**Why:** proper access control for untrusted physical ports — unknown device → denied/quarantine VLAN.
Cameras/APs can't do cert 802.1X, so use **MAB** (authenticate by MAC). Note: MAB is **spoofable**,
so it raises the bar but #3 (VLAN confinement) is the durable control.

1. **Settings → Profiles → RADIUS → Create** (UniFi has a **built-in RADIUS server** — enable it;
   today only the placeholder "Default" profile exists). Or point at external FreeRADIUS.
2. Add each allowed device's **MAC as a RADIUS user** (MAB), mapped to its VLAN.
3. On the exposed switch ports: **802.1X Control = MAC-based** (or Auto), RADIUS profile = above,
   set a **fallback/quarantine VLAN** for unknown MACs.
4. Roll out to one exposed switch, verify cameras/APs still authenticate, then the rest.

---

## 5. L2 + physical hardening (quick wins)  (M103 / #18)

- **DHCP Guard / Snooping** on the exposed switches (block a rogue plugged-in DHCP server).
- **Port Isolation** on camera/IoT ports (a hijacked port can't reach the adjacent camera).
- **Loop/Storm control** (prevent disruption from a plugged-in device).
- **Physical:** weatherproof **lockboxes** for the outdoor switches; set a device password; SSH off.

---

## 6. M47 follow-up — add the `UDM_API_KEY` GitHub secret  (one-time)

`udm-firewall.yml` now prefers `X-API-Key` (with a username/password fallback). To make **CI**
use the key (then we drop the fallback):

1. Get the key value: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d infra/ansible/playbooks/secrets/homelab-ops.sops.yaml` → `udm_api_key`.
2. **GitHub → repo → Settings → Secrets and variables → Actions → New repository secret** →
   name `UDM_API_KEY`, value = that key.
3. Ping the agent → it removes the `UDM_USERNAME/PASSWORD` login fallback from the playbook +
   the old GH secrets.

---

## 7. (Optional, lower priority) L24 — authenticate the MetalLB↔UDM BGP sessions

Add a BGP password (MD5/auth) on both sides. UDM BGP is **UI/FRR-only** (no API): edit the
FRR config in the UniFi BGP section (Settings → Routing → BGP, or the FRR config upload) to add
`neighbor <peer> password <secret>`, and set the matching password on the MetalLB `BGPPeer`
(`platform/kubernetes/metallb/`). Keep the git-stored FRR config in sync. Low urgency (the BGP
fabric is internal/LAN).
