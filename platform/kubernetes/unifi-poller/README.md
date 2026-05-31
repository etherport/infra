# unifi-poller (unpoller) — UniFi telemetry → Prometheus

Tracker **M55** / task #15. Closes the UDM metrics gap: today Prometheus has only
`probe_success` (blackbox reachability) + `unifi_backup_*`. unpoller scrapes the
UDM controller API and exposes client counts, throughput, WAN, per-port/PoE,
AP/client RSSI, DPI, and per-device health as `unifi_*` series.

## Status: LIVE (activated 2026-05-31)

Deployed + wired into Flux; Prometheus target `serviceMonitor/unifi-poller/…`
is `up` and `unpoller_*` series are ingesting. Creds live in 1Password
`UDM (unifi-poller)` (View-Only local admin) and in the SOPS secret
`01-secret.sops.yaml`. Metrics namespace is **`unpoller_`** (see below).

## Activation (3 steps, ~5 min)

1. **Create the View-Only account** — UniFi OS → Settings → Admins & Users →
   Add Admin → *Restrict to local access only* → role **View Only**. Use a
   dedicated username (not `tf-admin`). Note the username + password.

2. **Encrypt the Secret:**
   ```sh
   cd platform/kubernetes/unifi-poller
   cp 01-secret.sops.yaml.example 01-secret.sops.yaml
   # edit 01-secret.sops.yaml — set username + password
   sops -e -i 01-secret.sops.yaml         # encrypts data/stringData in place
   ```

3. **Enable in Flux** — uncomment both lines, then commit + push:
   - `01-secret.sops.yaml` in `platform/kubernetes/unifi-poller/kustomization.yaml`
   - `- ../../platform/kubernetes/unifi-poller` in `clusters/wind/kustomization.yaml`

   Flux reconciles; verify:
   ```sh
   kubectl -n unifi-poller rollout status deploy/unifi-poller
   kubectl -n unifi-poller logs deploy/unifi-poller | grep -i "updating\|polling\|sites"
   # Prometheus should list the target:
   #   up{job="unifi-poller"} == 1   and   unifi_* series populated
   ```

## Grafana dashboards

Metrics namespace is **`unpoller_`** (v2 default) — when importing, pick the
**Prometheus** variants of the unpoller dashboards (the older Influx-era ones
query `unifi_*` and won't match). Datasource = the Prometheus in `monitoring`:

| ID | Dashboard |
|----|-----------|
| 11315 | UniFi-Poller: Switches (USW) |
| 11314 | UniFi-Poller: Network Sites |
| 11311 | UniFi-Poller: Client Insights |
| 11312 | UniFi-Poller: Access Points (UAP) |
| 11313 | UniFi-Poller: Gateways (USG/UDM) |

## Notes

- **Connectivity:** the pod (VLAN 201) reaches the UDM API at
  `https://10.10.200.1` (VLAN 200) over the UDM's inter-VLAN routing — the same
  path the `unifi-backup` cronjob already uses, so no new firewall allow is
  expected. If the target is down, confirm 201→200 :443 is permitted.
- **TLS:** `UP_UNIFI_DEFAULT_VERIFY_SSL=false` — the UDM serves its internal
  self-signed cert on the controller API.
- **Image automation:** the deployment carries the Flux `$imagepolicy` marker;
  add an `ImagePolicy`/`ImageRepository` for `ghcr.io/unpoller/unpoller` if you
  want auto-bumps (optional — pinned to `v2.15.3` otherwise).
