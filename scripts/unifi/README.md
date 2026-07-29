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

### Why MAB, not port-security MAC-pinning
The ubiquiti-community fork makes "port uses a named profile (`portconf_id`)" and
"port has manual `port_security_enabled`" **mutually exclusive** — a raw
port-security PUT on a profiled port is silently stripped (verified 2026-07-29).
MAB via `dot1x_ctrl: mac_based` is orthogonal to the VLAN profile, so it keeps
the profile intact **and** yields an auth-failure signal (UDM event log → Phase-3
alerting). That's the profile-compatible, best-practice path.

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
