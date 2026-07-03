# Runbook — UDM/UniFi manual hardening actions (console-only)

Network-hardening items that **can't be done via IaC** (the `ubiquiti-community/unifi` TF provider
+ `udm-firewall.yml` don't cover them) and need the UniFi console. Created 2026-06-24
from the network-hardening cleanup pass. Do these in one sitting; tick them off + ping the
agent to update the tracker (M105 / M104 / M47 follow-up / L24).

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

## 2. Unused switch ports → Disabled  (M105 — do the EXPOSED switches first, #18)

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

## 3. Per-port VLAN minimisation on exposed switches  (M105 / #18)

**Why:** so a *hijacked* active port (unplug a camera, plug in) lands in an already-isolated,
zoned VLAN — not a trusted network. This is the real blast-radius control (MAC filtering is spoofable).

For each **active** port on the exposed switches, set its native/access network to **only** what
that device needs:
- **Camera ports → `Security` (205)** (already zone-isolated).
- **Outdoor AP ports → only their SSID VLAN(s)** — not a trunk-all.
- **`ua-gate` (UniFi Access) → a dedicated Access/door VLAN**, isolated to the Access controller.

UniFi Devices → switch → port → **Native/Access Network** = the specific VLAN; tagged networks = only what's required.

---

## 4. 802.1X + MAC-Auth-Bypass (MAB) — project, not a quick toggle  (M105 / #18)

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

## 5. L2 + physical hardening (quick wins)  (M105 / #18)

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

## 7. ✅ DONE (2026-06-28) — L24 authenticate the MetalLB↔UDM BGP sessions

**No longer outstanding.** TCP-MD5 is live on the eBGP session and verified both ends.
MetalLB was migrated **native (kubespray addon) → FRR mode on the Helm chart** (Flux-managed,
`clusters/wind/helm-releases/metallb.yaml`) — FRR mode was the prerequisite, since native/gobgp
can't honour `passwordSecret`. The key is the SOPS secret `bgp-md5`
(`platform/kubernetes/metallb/02-bgp-md5-secret.sops.yaml`), referenced by the `BGPPeer/udm`
`spec.passwordSecret`; the **same** value is set as the `neighbor metallb password …` on the UDM
FRR peer-group (UI-only/no-API). ASN 64513 (cluster) ↔ 64512 (UDM @ `10.10.201.1`). Commits
`67773a7` / `3c890bc` / `8a16805`. Full record: L24 in `docs/planning/outstanding-work.md`.

---

## 8. M71 — kill the standing static AWS keys on the mini (+ rotate)

The **devbox** is already clean (M82 removed its standing key; TF is CI-only). What's left is
the **mini's** standing plaintext keys in `~/.aws/credentials` — a mini/admin action (the agent
can't reach it headlessly). Two standing profiles today:
- `[homelab]` = terraform-homelab — **bounded** (6 `terraform-*` policies, no IAM, M97-tightened).
- `[claude-admin]` = **PowerUserAccess** break-glass — the high-blast-radius one.

**Interim win (a) — biggest cut, ~0 effort (do first):** remove the `[claude-admin]` block from
the mini's standing `~/.aws/credentials`. Use it only when break-glass is actually needed, pulled
from SOPS / your laptop on demand. CI doesn't need it (CI is OIDC since H29). On the mini:
```bash
aws configure --profile claude-admin list 2>/dev/null   # confirm it's there
# edit ~/.aws/credentials and delete the [claude-admin] block (keep [homelab] for now)
```

**Interim win (b) — rotate the never-rotated keys + set a cadence:** both keys predate 2026-01.
terraform-homelab can't rotate itself (no IAM) — rotate from `claude-admin`/`gs_admin`:
```bash
# as an admin (claude-admin/gs_admin), for each user (terraform-homelab, claude-admin):
aws iam create-access-key --user-name <user>           # note the new key
# update the SOPS ops bundle (aws_access_key_id/secret) so render-aws-credentials + the
# mini's [homelab] use the new key:  sops set infra/ansible/playbooks/secrets/homelab-ops.sops.yaml ...
# re-render on the mini + devbox-on-demand; verify a terraform plan still works; then:
aws iam delete-access-key --user-name <user> --access-key-id <OLD>
```
Set a reminder cadence (e.g. quarterly). NB the `terraform-homelab` IAM **user/key must not be
deleted outright** — it's the shared local-ops key (H29); only **rotate** it.

**Target architecture (the proper fix, when ready):** mini → **IAM Roles Anywhere** (X.509 trust
anchor + `aws_signing_helper` `credential_process` → short-lived creds, zero standing key);
human laptops → **IAM Identity Center (SSO)**. See M71 in `outstanding-work.md` for the rationale.
