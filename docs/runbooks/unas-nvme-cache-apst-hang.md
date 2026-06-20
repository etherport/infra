# Runbook: UNAS SSD-cache member drop / NVMe APST controller hang

**First seen:** 2026-06-19. **Device:** UNAS Pro (`10.10.209.10`, Sequoia, UniFi-OS).
**Affected:** `md4` = the **SSD read-write cache RAID1** (two M.2 NVMe). The RAID6 data
array (`md3`) and system mirror (`md0`) were unaffected.

## Symptom
- UNAS UI: **Storage Pool "At Risk"**, **SSD Cache "Transferring"/"Repairing"**, while
  **every individual drive still shows "Optimal"/healthy** (incl. both cache SSDs).
- Downstream: **SMB to the NAS degrades** — reads hang / throw I/O errors within ~1
  min, even on a freshly rebuilt mount (this is often the *first* thing noticed; e.g.
  the Mac-mini photo-backup agent reported it before the NAS UI was checked).
- On the NAS: **high load average** (processes blocked in `D`/uninterruptible I/O —
  `smbd`, `kcopyd`, `btrfs-transaction`), and `lvs`/storage commands hang.

## Why the UI says the drive is "healthy" when it isn't
**SMART health ≠ bus presence.** The failure mode here is the SSD's NVMe controller
**falling off the PCIe bus** (`nvme nvme0: controller is down; CSTS=0xffffffff`,
`Removing after probe failure status: -19`). A drive that *vanishes* can't report bad
SMART — so the per-drive widget keeps showing its **last-known-good** reading. Only
the pool status (reading live `md` state) reflects the failure. Confirm via the bus,
not SMART: **`ls /dev/nvme*`** — a dropped drive's device node is simply gone.

## Root cause (2026-06-19)
A firmware update earlier that day (`UNASPRO ... v5.1.19 ... 260613`) rebooted the
NAS at 06:17. It ran fine ~5 h, then at ~11:04 **`nvme0`'s controller hung and dropped
off the bus** — the textbook **NVMe deep-power-state (APST) hang** signature
(`CSTS=0xffffffff`, hours into runtime, on an activity dip — not at boot). `md`
kicked `nvme0p2` from `md4`; the cache ran **degraded** on the surviving `nvme1`.
- **Data was never at risk:** the cache is RAID1 (survivor `nvme1` intact, SMART
  pristine) and the RAID6 data array stayed `[8/8]`.
- The new firmware's power-management behavior is the prime suspect (vs. a marginal
  M.2). `default_ps_max_latency_us=100000` permits the deep APST states; the appliance
  kernel cmdline is fixed, so we **can't persistently disable APST** ourselves.

## Diagnose (read-only SSH)
SSH with the `unifi-cert-sync@homelab` key (decrypt from
`platform/kubernetes/unifi-backup/01-secret-ssh.sops.yaml`, or use
`infra/unifi-devices/unas/snapshot.sh`'s pattern):
```bash
ssh root@10.10.209.10 'cat /proc/mdstat'          # md4 [2/1] [_U] = degraded
ssh root@10.10.209.10 'ls -l /dev/nvme*'          # is the device node even present?
ssh root@10.10.209.10 'dmesg | grep -iE "nvme|md/raid|I/O error|controller is down" | tail'
ssh root@10.10.209.10 'mdadm --detail /dev/md4'   # State, Failed/Spare devices, Rebuild Status
ssh root@10.10.209.10 'uptime; ps -eo state,comm | grep "^D"'   # load + D-state procs
```

## Fix (≈2 min reboot + an automatic cache rebuild)
A reboot clears the hung D-state I/O and re-probes the dropped SSD. **Safe even
mid-"Transferring" here** because the cache is RAID1 — the surviving SSD holds all
data (incl. un-flushed write-back) across the reboot. (This is the *opposite* of a
single/RAID0 cache, where a reboot mid-flush risks the un-flushed writes.)
1. **Reboot the NAS** — graceful from the UI ("Restart Console") first. It may stall
   on the D-state tasks; if it's not back in a few minutes a hard power-cycle is
   acceptable (RAID1 survivor + clean RAID6 protect the data).
2. On boot, the dropped SSD re-probes and `md4` **auto-rebuilds** (UI shows
   "Repairing"). Watch it: `cat /proc/mdstat` → `recovery = NN%`. ~1 TB mirror ≈
   30–100 min at ~150 MB/s.
3. **Done when** `md4` is back to `[2/2] [UU]`, State `clean` — pool returns to
   Healthy. Then resume any paused workload (e.g. the photos export).

> NB: SSH may come up **disabled/late** in the first ~minute of boot (port 22 closed
> while UI:443 / SMB:445 are already open). That's normal — it's not the NAS being
> down. If SSH stays off, re-enable it in the UNAS UI (the cert-sync pubkey is
> already authorized).

## Durability
- **Monitoring (the gap this incident exposed):** `platform/kubernetes/unas-health/`
  now SSHes every 15 min, reads `/proc/mdstat`, and fires **`UnasMdArrayDegraded`**
  (+ check-failing / stale watchdogs) so a future member drop **pages within ~15 min**
  instead of being noticed via an SMB hang. No more relying on the UI's stale
  per-drive "healthy".
- **If it recurs** (the tell that it's the firmware, not a one-off): nvme0 dropping
  again on this firmware ⇒ (1) report to Ubiquiti with this evidence (firmware
  v5.1.19, `CSTS=0xffffffff` APST signature), (2) consider a firmware rollback, (3)
  swap `nvme0` for a different SSD model as a hardware hedge. We **cannot** persist
  `nvme_core.default_ps_max_latency_us=0` on the locked appliance.
- **Don't** tighten/poke runtime NVMe power settings on the live NAS as a "fix" — not
  persistable and not worth the risk on production storage.
