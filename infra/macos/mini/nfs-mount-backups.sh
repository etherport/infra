#!/bin/bash
# Mount the UNAS "Backups" share over NFS at /Volumes/Backups — Phase 1 of the SMB→NFS
# migration (2026-07-11). Runs as ROOT via the net.wind.nfs-backups LaunchDaemon
# (RunAtLoad + StartInterval=180), so it needs no keychain, no NetAuth, no GUI — the
# entire class of "SMB session died → macOS demands a console click" outages
# (2026-07-03→09, 07-10→11) cannot happen on this path. The k8s s3-sync has read this
# same export over NFS through every one of those SMB outages without a single failure.
#
# Design notes (each learned the hard way):
# - `soft` + `nolocks`: a NAS outage must FAIL I/O, never hang cairn holding its run
#   lock (the agent-wedge class). cairn's writes are rsync temp+rename — no byte-range
#   locks needed; guards + --update make failed writes safe to retry.
# - resvport: the export is `secure` (privileged source port required) — root-only,
#   which is why this is a LaunchDaemon and not a user LaunchAgent.
# - mkdir JUST before mount + rmdir on failure: a bare /Volumes/Backups directory left
#   behind would pass cairn's "destination exists + readable" gate as an EMPTY LOCAL
#   DIR → jobs would mirror onto the mini's 15 GB disk instead of failing loudly.
# - If SMB currently holds the mountpoint (pre-cutover state or cairn's legacy heal),
#   replace it: force-unmount, then NFS-mount.
set -uo pipefail

SERVER="sequoia.wind.etherport.net"
# Primary = the path the k8s CronJobs mount (proven); fallback = the literal export
# root from `showmount -e` (UniFi Drive's /volume/<uuid>/... form) in case mountd
# stops resolving the friendly path after a UNAS update.
PATHS=(
  "/var/nfs/shared/Backups"
  "/volume/57af8df9-02a8-4f09-8413-8a01e652e1ac/.srv/.unifi-drive/Backups/.data"
)
VOL="/Volumes/Backups"
OPTS="resvport,soft,intr,nolocks,rsize=65536,wsize=65536,timeo=30,retrans=3"
LOG="/Users/grahamsmith/Library/Logs/nfs-backups.log"

log(){ echo "$(date '+%Y-%m-%dT%H:%M:%S') nfs-backups: $*" >> "$LOG"; }

# readable = mounted as NFS AND a bounded directory read finds real entries (a stale
# NFS mount with `soft` errors fast rather than hanging; perl alarm bounds it anyway —
# macOS has no /usr/bin/timeout). Requiring >2 entries (beyond . and ..) also rejects
# an accidentally-empty mount being mistaken for the populated share.
nfs_mounted(){ mount -t nfs | grep -qF " on ${VOL} "; }
vol_readable(){
  perl -e 'alarm 15; opendir(my $d, $ARGV[0]) or exit 1; my @e = readdir $d; exit(@e > 2 ? 0 : 1)' "${VOL}" 2>/dev/null
}

# 0. Healthy already → done (the common case; keep the tick silent + cheap).
if nfs_mounted && vol_readable; then
  exit 0
fi

# 1. Something unhealthy holds the mountpoint (stale NFS, or SMB pre-cutover) → clear it.
if mount | grep -qF " on ${VOL} "; then
  kind="$(mount | grep -F " on ${VOL} " | sed 's/.*(//;s/,.*//')"
  log "⚠ ${VOL} is mounted (${kind}) but unhealthy or not NFS — force-unmounting to replace"
  umount -f "${VOL}" 2>/dev/null || diskutil unmount force "${VOL}" >/dev/null 2>&1 || {
    log "✗ could not unmount ${VOL} — will retry next tick"; exit 1; }
  sleep 2
fi

# 2. Reachability gate (rpcbind answers = NFS service up; no auth concept to wedge).
if ! nc -z -G3 "${SERVER}" 2049 >/dev/null 2>&1; then
  log "✗ ${SERVER}:2049 unreachable (NAS down / network) — not attempting mount"
  exit 1
fi

# 3. Mount: fresh mountpoint, try each export path, verify readable, else clean up.
mkdir -p "${VOL}"
for path in "${PATHS[@]}"; do
  if mount -t nfs -o "${OPTS}" "${SERVER}:${path}" "${VOL}" 2>>"$LOG"; then
    if vol_readable; then
      log "▶ mounted ${SERVER}:${path} at ${VOL} (nfs, ${OPTS})"
      exit 0
    fi
    log "⚠ mounted ${path} but unreadable — unmounting and trying next path"
    umount -f "${VOL}" 2>/dev/null
  fi
done

# 4. Every path failed: remove the bare dir so nothing mistakes it for a destination.
rmdir "${VOL}" 2>/dev/null
log "✗ NFS mount failed for all export paths — bare mountpoint removed; retry next tick"
exit 1
