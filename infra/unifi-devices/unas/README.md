# UNAS (Sequoia) — config as code

The UNAS Pro is a UniFi-OS appliance: its share/export/user config lives in
internal Postgres and is managed via the UI, so there's **no clean write-API to
manage it as IaC**. Instead we keep a **human-readable state backup in git** as a
rebuild reference, and the device's `core-config` rides the existing S3 backup.

## Files
| File | What |
|---|---|
| `config-snapshot.md` | Captured state: device, network, shares, NAS users, and the **authoritative NFS export ACLs** (which hosts mount which shares, ro/rw, squash). Rebuild-critical. |
| `snapshot.sh` | Regenerates `config-snapshot.md` read-only over SSH. Re-run after share/export changes (or on a schedule) and commit the diff. |

## Monitoring
**md (software-RAID) health is alerted** by `platform/kubernetes/unas-health/` — a
CronJob SSHes every 15 min, reads `/proc/mdstat`, and fires `UnasMdArrayDegraded` if
any array (SSD cache `md4` / RAID6 data `md3`) loses a member. Added 2026-06-19 after
an NVMe cache drive dropped off the bus and ran degraded for hours unalerted (UI
still showed it "healthy"): [`docs/runbooks/unas-nvme-cache-apst-hang.md`](../../../docs/runbooks/unas-nvme-cache-apst-hang.md).

## Access
SSH key **`unifi-cert-sync@homelab`** (the same key the `unifi-backup`/`cert-sync`
CronJobs use for the UDM + Protect) is authorized in the UNAS `/root/.ssh/authorized_keys`.

**Rebuild note:** a UNAS factory-reset wipes `authorized_keys` *and* the NFS export
ACLs. After a rebuild: (1) re-add the `unifi-cert-sync@homelab` pubkey to the UNAS
(UI SSH keys or `/root/.ssh/authorized_keys`), then (2) re-apply the export ACLs in
`config-snapshot.md` (Settings → Shares → each share → NFS → allowed hosts).

## Refresh
```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt infra/unifi-devices/unas/snapshot.sh
git add infra/unifi-devices/unas/config-snapshot.md && git commit
```
