#!/bin/bash
# One-time installer for the Backups-over-NFS LaunchDaemon (Phase 1 of SMB→NFS).
# RUN WITH SUDO on the mini:  sudo infra/macos/mini/install-nfs-backups.sh
#
# Does, in order:
#   1. installs net.wind.nfs-backups.plist into /Library/LaunchDaemons (root:wheel 644)
#   2. unmounts the SMB Backups mount if present (the daemon replaces it with NFS)
#   3. bootstraps + kickstarts the daemon → NFS mount comes up within seconds
#   4. verifies: /Volumes/Backups is NFS-mounted and readable
# Rollback: sudo launchctl bootout system/net.wind.nfs-backups
#           sudo rm /Library/LaunchDaemons/net.wind.nfs-backups.plist
#           then re-add Backups to SHARES in mount-nas.sh (git revert) — SMB resumes.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_SRC="${HERE}/net.wind.nfs-backups.plist"
PLIST_DST="/Library/LaunchDaemons/net.wind.nfs-backups.plist"
LABEL="net.wind.nfs-backups"

echo ">>> installing ${PLIST_DST}"
install -m 644 -o root -g wheel "${PLIST_SRC}" "${PLIST_DST}"
chmod +x "${HERE}/nfs-mount-backups.sh"

if mount | grep -qF " on /Volumes/Backups " && ! mount -t nfs | grep -qF " on /Volumes/Backups "; then
  echo ">>> unmounting the existing SMB Backups mount (being replaced by NFS)"
  umount -f /Volumes/Backups 2>/dev/null || diskutil unmount force /Volumes/Backups || true
  sleep 2
fi

echo ">>> loading the daemon"
launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "${PLIST_DST}"
launchctl kickstart -k "system/${LABEL}"

echo ">>> waiting for the NFS mount"
for i in $(seq 1 15); do
  sleep 2
  if mount -t nfs | grep -qF " on /Volumes/Backups "; then
    echo ">>> ✓ NFS mounted:"
    mount -t nfs | grep -F " on /Volumes/Backups "
    ls /Volumes/Backups | head -5
    echo ">>> done. cairn's next runs write over NFS; watch ~/Library/Logs/nfs-backups.log"
    exit 0
  fi
done
echo ">>> ✗ NFS mount did not come up — see /Users/grahamsmith/Library/Logs/nfs-backups.log"
exit 1
