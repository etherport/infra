# Onboard a New Device to the Loki Syslog Stream

Procedure for pointing a new device's syslog at the Alloy receiver so
its logs flow into Loki + show up in Grafana with friendly labels.

Receiver: **`10.10.201.73:514`** (UDP + TCP). MetalLB LoadBalancer
fronting Alloy DaemonSet. RFC3164 (BSD-style) syslog format; clients
do NOT need to speak RFC5424.

## Devices already onboarded

| Device | UI path to enable | Friendly label |
|---|---|---|
| UDM Pro Max | Network app → Settings → CyberSecure → Traffic Logging → SIEM Server → `10.10.201.73:514` | `udm` |
| UniFi switches (×7) | UniFi controller → Devices → \<switch\> → System Logging → Server `10.10.201.73:514` | `switch-<name>` |
| UniFi APs (×7) | UniFi controller → Devices → \<AP\> → System Logging → Server `10.10.201.73:514` | `ap-<name>` |
| PVE host | Ansible `ipmi-monitoring.yml` configures rsyslog forward to `10.10.201.73:514` | `pve` |
| PVE BMC (ASRock Rack) | BMC UI → Settings → Advanced Log Settings → Remote Log enabled, UDP, `10.10.201.73:514` | `pve-bmc` |

## UNVR / UniFi Protect controller (M45)

The Protect controller at `10.10.212.10` runs its own app and has its
own logging config (separate from the Network app).

1. Browse to `https://10.10.212.10/protect/settings/advanced` (or
   Settings → Advanced from the Protect UI).
2. Find **Remote Logging** (sometimes under "Diagnostics" or
   "System"; UI varies by firmware).
3. Enable + set:
   - Server: `10.10.201.73`
   - Port: `514`
   - Protocol: `UDP`
   - Format: `BSD / RFC3164` (default)
4. Save. New logs should arrive within ~30s under
   `{host="unvr"}` in Grafana (the friendly-name relabel rule
   matches `^UNVR.*` → `unvr`).

If the Protect UI doesn't expose Remote Logging, fall back to
SSH into the UNVR:

```bash
ssh root@10.10.212.10
# Add to /etc/rsyslog.d/40-loki.conf:
echo '*.*  action(type="omfwd" target="10.10.201.73" port="514" protocol="udp")' \
  > /etc/rsyslog.d/40-loki.conf
systemctl restart rsyslog
```

The UNVR's stock rsyslog should be running already; only the
forward config is missing.

## UNAS / Sequoia (M45)

Sequoia (`10.10.209.10`, VLAN 209) is a UniFi NAS device.

1. Browse to `https://10.10.209.10` and log in.
2. Settings → System → **Logging** (or similar — UI varies by
   firmware version).
3. Enable **Remote Syslog**:
   - Server: `10.10.201.73`
   - Port: `514`
   - Protocol: `UDP`
4. Save.

New logs arrive under `{host="unas-sequoia"}` (the relabel rule
matches `^Sequoia.*` → `unas-sequoia`).

If the Web UI doesn't expose syslog (some early UNAS firmware
doesn't), SSH approach:

```bash
ssh root@10.10.209.10
echo '*.*  action(type="omfwd" target="10.10.201.73" port="514" protocol="udp")' \
  > /etc/rsyslog.d/40-loki.conf
systemctl restart rsyslog
```

## Verifying a new device

Within ~30s of enabling syslog forwarding, run:

```bash
# Distinct host labels in Loki:
kubectl run lh --rm -i --restart=Never --image=curlimages/curl:latest --quiet --command -- \
  curl -s "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/label/host/values" 2>&1 | tail -3
```

You should see the new friendly label (e.g. `unvr` / `unas-sequoia`)
in the list. If you see the device's RAW hostname instead (e.g.
`UNVR-Pro-Max` or `SequoiaXR`), the relabel rule didn't match.

To add a new pattern, edit `clusters/wind/helm-releases/alloy.yaml`
and add a rule in the `loki.relabel "syslog"` block before the final
`lowercase` pass:

```alloy
rule {
  source_labels = ["host"]
  regex         = "^MyNewDevice.*"
  target_label  = "host"
  replacement   = "my-friendly-name"
  action        = "replace"
}
```

Commit + push. Flux applies in ~1 min. Old log lines keep their
original labels until 30-day retention rotates them; new lines get
the friendly label immediately.

## Querying

In Grafana → Explore → Loki:

```logql
{host="udm"}                               # UDM only
{host=~"ap-.*"}                            # all APs
{host=~"switch-.*", severity="err"}        # switch errors only
{host="unvr"} |~ "(?i)disk|drive|smart"    # UNVR storage events
{host="unas-sequoia"} |~ "(?i)raid|md|zfs" # NAS storage events
```

The Service Browser view groups by `service_name`, which Alloy now
sets to the same value as `host` (verified 2026-05-24 in the
loki.relabel "syslog" block).
