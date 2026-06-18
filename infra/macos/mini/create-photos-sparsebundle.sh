#!/bin/bash
# Create the APFS sparsebundle that hosts the iCloud Photos library for M79.
#
# WHY a sparsebundle on the NAS: osxphotos exports from a *local* Photos library,
# but the mini has only ~11-40 GB free — nowhere near a full "Download Originals"
# library. A sparsebundle is a disk image whose bands are allocated on demand and
# whose bits live on the NAS (SMB), while macOS sees a normal *local* APFS volume
# once attached. Photos.app then treats it like any local library. The bundle
# itself (one huge multi-GB file) is the working library and is EXCLUDED from S3 —
# only the osxphotos *export* (individual files + XMP sidecars) is backed up.
#
# Idempotent: refuses to clobber an existing bundle. Safe to re-run.
#
# Caveat (accepted): a sparsebundle over a network link can corrupt if the link
# drops mid-write (same risk model as Time Machine over the network). Acceptable
# here because the library is just a cache of iCloud — corruption = rebuild, not
# data loss. The robust alternative is an external APFS SSD on the mini.
#
# After this succeeds, the owner attaches it and points Photos.app at it — see
# README.md "M79 owner steps".
set -euo pipefail

# --- config ---
NAS_DIR="/Volumes/Personal-Drive/Photos"
BUNDLE="${NAS_DIR}/PhotosLibrary.sparsebundle"
SIZE="2t"            # sparse ceiling; near-zero bytes used until the library fills
VOLNAME="PhotosLib" # APFS volume label shown when attached

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') create-photos-sparsebundle: $*"; }

# --- preflight: NAS mounted? ---
if ! mount | grep -qF " on /Volumes/Personal-Drive "; then
  log "✗ /Volumes/Personal-Drive not mounted. Run ./mount-nas.sh first."
  exit 1
fi

if [ -e "${BUNDLE}" ]; then
  log "✓ already exists: ${BUNDLE} (refusing to clobber). Nothing to do."
  exit 0
fi

mkdir -p "${NAS_DIR}"

log "creating ${SIZE} APFS sparsebundle at ${BUNDLE} (volname ${VOLNAME})"
# -type SPARSEBUNDLE: band-based, grows on demand, network-friendly.
# -fs APFS: required for a modern Photos library.
# -nospotlight: don't index the image contents on the NAS-backed volume.
hdiutil create \
  -size "${SIZE}" \
  -type SPARSEBUNDLE \
  -fs APFS \
  -volname "${VOLNAME}" \
  -nospotlight \
  "${BUNDLE}"

log "✓ created. Attach with:  hdiutil attach \"${BUNDLE}\""
log "  then Option-launch Photos.app and choose the volume under /Volumes/${VOLNAME}."
