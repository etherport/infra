#!/bin/bash
# Ensure the NAS SMB shares needed by the iCloud backup pipeline are mounted at
# their standard /Volumes/<share> paths. Idempotent — safe to re-run any time.
#
#   /Volumes/Personal-Drive  — holds the Photos library APFS sparsebundle (M79)
#   /Volumes/Backups         — export target; the k8s aws-s3-sync "backups" share
#                              reads this same NAS share over NFS and ships it to S3
#
# Uses `open smb://` (what Finder does) rather than `mount_smbfs` to a custom path:
# macOS auto-mounts SMB shares under /Volumes/<share>, and mounting the same share
# again at a different path fails with "File exists" (EEXIST). The password is
# resolved non-interactively from the login keychain (nothing secret committed).
#
# The osxphotos export job re-runs this in its preflight, so a dropped mount
# self-heals. See README.md.
set -uo pipefail

SERVER="sequoia.wind.etherport.net"
SMB_USER="graham"
SHARES=(Personal-Drive Backups)

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') mount-nas: $*"; }

rc=0
for share in "${SHARES[@]}"; do
  vol="/Volumes/${share}"
  if mount | grep -qF " on ${vol} "; then
    log "✓ ${share}: already mounted at ${vol}"
    continue
  fi

  log "mounting ${share} via open smb://${SERVER}/${share}"
  open "smb://${SMB_USER}@${SERVER}/${share}"

  mounted=false
  for i in $(seq 1 20); do            # `open` is async — poll ~40s
    sleep 2
    if mount | grep -qF " on ${vol} "; then
      log "▶ ${share}: mounted at ${vol} (after $((i * 2))s)"
      mounted=true
      break
    fi
  done
  if [ "$mounted" = false ]; then
    log "✗ ${share}: NOT mounted after ~40s (NAS down? keychain entry missing?)"
    rc=1
  fi
done

exit "$rc"
