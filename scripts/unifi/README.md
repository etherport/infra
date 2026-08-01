# scripts/unifi

## port-auth.py — switch-port MAB (802.1X MAC-auth) manager (#18 phase 2)

Idempotent, git-driven port authentication for the physically-exposed edge
ports. Desired state lives in `port-auth.yaml` (repo = source of truth); the
script reconciles the UDM to match. Design + rationale:
`docs/planning/dot1x-mab-design-2026-07-29.md`.

```bash
./port-auth.py                       # dry-run: diff vs desired-state (default)
./port-auth.py --apply               # write port dot1x_ctrl + RADIUS accounts
./port-auth.py --rollback "Switch Chapel" --apply   # force that switch's ports back to open
```

Auth: `UNIFI_API_KEY` env, else it `sops -d`'s `udm_api_key` from the ops bundle.

### How it works (profile-swap, verified end-to-end 2026-08-01)
This controller strips per-port auth fields (`port_security_*` AND `dot1x_ctrl`)
from any override that has a `portconf_id` — so auth must live in the PORT
PROFILE, not the override. Bootstrap (one-time, already done):
1. A **"Cameras MAB"** portconf = clone of "UniFi Devices" + `dot1x_ctrl: mac_based`.
2. Global `global_switch.dot1x_portctrl_enabled = true` (RADIUS profile already set).
3. A RADIUS account per camera MAC (username=password=lowercase MAC).
The script then just **swaps a port's profile** between "UniFi Devices" (`open`)
and "Cameras MAB" (`mab`). VLAN is identical (MAB profile is a clone). Proven by
PoE-cutting a camera and watching the fresh link-up authenticate via RADIUS.

### Safety built in
- **Refuses uplink/transit ports** (it derives them from the live uplink graph) —
  MAB on an uplink breaks everything downstream. This already caught one
  mis-listed port during authoring.
- **Dry-run is the default**; `--apply` required to write.
- After apply it re-reads and **warns if a targeted port went DOWN** (a real
  device that failed auth) with the exact rollback command.
- Paces writes (the UDM rate-limiter trips under rapid calls).

### Cutover procedure (do when physically home)
Gate/intercom/camera ports are physical-access devices — a bad cutover = gate
dark. So: flip the **pilot** (`Switch Chapel` p1) to `mode: mab`, `--apply`,
soak 48h watching the UDM event log, then convert the rest one switch at a time.
`port-auth.yaml` ships with everything `mode: open` (no-op) until you're ready.
