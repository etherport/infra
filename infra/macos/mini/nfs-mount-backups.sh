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
# - A SLOW probe is not a DEAD mount, and the remediation here is destructive
#   (2026-07-16: cairn's own rsync+osxphotos load drove loadavg to 39; the old 15s
#   probe timed out on a perfectly healthy mount → this script force-unmounted the
#   volume out from under the running job → 6 jobs rc=1 "destination base not
#   reachable"). So: a generous probe timeout, N consecutive failures before anything
#   destructive, and never tear down a mount we have not first confirmed we can replace.
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

# Probe budget: must exceed how long a readdir takes while cairn is hammering the
# mount, not how long it takes when idle. `soft` means a genuinely dead mount errors
# out well inside this — the alarm only catches "slow", which is why it is not a
# remediation trigger on its own.
PROBE_TIMEOUT=60
# Consecutive failed probes before destructive remediation. At StartInterval=180 this
# is ~9 min of sustained unreadability — far longer than any load spike, far shorter
# than a night. A genuinely stale mount fails cairn's own destination gate safely in
# the meantime (jobs rc=1, nothing written), so waiting costs a loud failure, not data.
FAIL_THRESHOLD=3
# /var/run is cleared on boot → the counter resets with the machine, which is correct:
# a fresh boot has no history worth carrying.
FAILSTATE="/var/run/nfs-backups.probe-fails"

log(){ echo "$(date '+%Y-%m-%dT%H:%M:%S') nfs-backups: $*" >> "$LOG"; }

fails_get(){
  local n; n="$(cat "${FAILSTATE}" 2>/dev/null)"
  case "${n}" in ''|*[!0-9]*) echo 0 ;; *) echo "${n}" ;; esac
}
fails_set(){ echo "$1" > "${FAILSTATE}" 2>/dev/null || true; }

# readable = mounted as NFS AND a bounded directory read finds real entries (a stale
# NFS mount with `soft` errors fast rather than hanging; perl alarm bounds it anyway —
# macOS has no /usr/bin/timeout). Requiring >2 entries (beyond . and ..) also rejects
# an accidentally-empty mount being mistaken for the populated share.
nfs_mounted(){ mount -t nfs | grep -qF " on ${VOL} "; }
vol_readable(){
  perl -e 'alarm $ARGV[1]; opendir(my $d, $ARGV[0]) or exit 1; my @e = readdir $d; exit(@e > 2 ? 0 : 1)' \
    "${VOL}" "${PROBE_TIMEOUT}" 2>/dev/null
}

# 0. Healthy already → clear the failure streak + done (the common case; silent + cheap).
if nfs_mounted && vol_readable; then
  fails_set 0
  exit 0
fi

# 1. NFS is mounted but the probe failed. Hold fire until the streak proves the mount is
#    genuinely stale rather than merely busy — see the 2026-07-16 note above.
if nfs_mounted; then
  n=$(( $(fails_get) + 1 ))
  fails_set "${n}"
  if [ "${n}" -lt "${FAIL_THRESHOLD}" ]; then
    log "⚠ probe failed (${n}/${FAIL_THRESHOLD}) — ${VOL} is NFS and may just be busy; leaving it mounted"
    exit 0
  fi
  log "⚠ probe failed ${n}× consecutively (≥${FAIL_THRESHOLD}) — treating the NFS mount as stale"
fi

# 2. Reachability gate BEFORE anything destructive (rpcbind answers = NFS service up; no
#    auth concept to wedge). Never tear down a mount we cannot replace.
if ! nc -z -G3 "${SERVER}" 2049 >/dev/null 2>&1; then
  log "✗ ${SERVER}:2049 unreachable (NAS down / network) — leaving any existing mount untouched"
  exit 1
fi

# 3. Clear whatever holds the mountpoint: a stale NFS mount past the threshold, or SMB
#    (pre-cutover / cairn's legacy heal) which is replaced immediately with no streak —
#    there is no working NFS mount to protect in that case.
if mount | grep -qF " on ${VOL} "; then
  kind="$(mount | grep -F " on ${VOL} " | sed 's/.*(//;s/[,)].*//')"
  log "⚠ ${VOL} is mounted (${kind}) but unhealthy or not NFS — force-unmounting to replace"
  umount -f "${VOL}" 2>/dev/null || diskutil unmount force "${VOL}" >/dev/null 2>&1 || {
    log "✗ could not unmount ${VOL} — will retry next tick"; exit 1; }
  sleep 2
fi

# 4. Mount: fresh mountpoint, try each export path, verify readable, else clean up.
mkdir -p "${VOL}"
for path in "${PATHS[@]}"; do
  if mount -t nfs -o "${OPTS}" "${SERVER}:${path}" "${VOL}" 2>>"$LOG"; then
    if vol_readable; then
      log "▶ mounted ${SERVER}:${path} at ${VOL} (nfs, ${OPTS})"
      fails_set 0
      exit 0
    fi
    log "⚠ mounted ${path} but unreadable — unmounting and trying next path"
    umount -f "${VOL}" 2>/dev/null
  fi
done

# 5. Every path failed: remove the bare dir so nothing mistakes it for a destination.
rmdir "${VOL}" 2>/dev/null
log "✗ NFS mount failed for all export paths — bare mountpoint removed; retry next tick"
exit 1
