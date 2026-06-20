# unas-health — UNAS software-RAID (md) degradation alerting

Closes a real gap found on **2026-06-19**: one of the UNAS NVMe SSD-cache drives
(`nvme0`) fell off the PCIe bus (an APST controller hang), the `md4` cache mirror
ran **degraded for hours with no alert**, and the UNAS UI even kept showing both
SSDs as "healthy" (it shows SMART, which can't report a drive that has *vanished
from the bus*). The only signal was a downstream SMB hang. This component makes md
degradation page directly.

Full incident + manual diagnosis/fix: [`docs/runbooks/unas-nvme-cache-apst-hang.md`](../../../docs/runbooks/unas-nvme-cache-apst-hang.md).

## How it works
A CronJob (every 15 min, namespace `backups`) SSHes to the UNAS with the existing
**`unifi-backup-ssh`** key (the `unifi-cert-sync@homelab` key already authorized on
the UNAS), reads `/proc/mdstat`, parses each array's `[total/active]` redundancy
token, and pushes gauges to **Pushgateway** (`job=unas_health`):

| Metric | Meaning |
|---|---|
| `unas_md_array_degraded{array}` | 1 if `active < total` (failed member OR rebuilding) |
| `unas_md_disks_active{array}` / `unas_md_disks_total{array}` | member counts |
| `unas_md_health_check_status` | 0 = SSH+read ok, 1 = couldn't reach the NAS |
| `unas_md_health_last_run_timestamp` | last successful run (staleness watchdog) |

`md4` = SSD read-write cache (RAID1) · `md3` = RAID6 data array · `md0` = system mirror.

## Alerts (`03-prometheusrule.yaml`)
- **`UnasMdArrayDegraded`** (warning, 15m) — a member failed/dropped or the array
  is rebuilding. A rebuild auto-resolves; a persistent degrade = failed member.
- **`UnasMdHealthCheckFailing`** (warning, 1h) — probe can't reach the NAS / SSH
  off (redundancy unmonitored). Note SSH can come up off after a firmware update.
- **`UnasMdHealthStale`** (warning, 1h) — the CronJob stopped pushing.

## Host key
`StrictHostKeyChecking=yes` against the pinned key in `01-script-configmap.yaml`.
After a UNAS factory-reset / host-key change, refresh it:
```sh
ssh-keyscan -t ed25519 10.10.209.10
```

## Notes
- Read-only: only `cat /proc/mdstat` runs on the UNAS.
- Reuses `unifi-backup-ssh` (namespace `backups`) — no new secret.
- A degraded array does **not** fail the Job (exit 0); only an unreachable NAS
  exits non-zero. The PrometheusRule owns the degrade signal.
