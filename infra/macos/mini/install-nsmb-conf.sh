#!/bin/bash
# Install the SMB client tuning to /etc/nsmb.conf — the path the macOS KERNEL SMB client
# authoritatively reads for `open smb://` / Finder / automounter mounts (M79; adversarial
# review C-3, 2026-06-22). The previous approach wrote ~/Library/Preferences/nsmb.conf, which
# is NOT honored for these kernel-initiated mounts — so the tuning (notify_off, mc_on,
# SMB2/3-only) was a silent no-op (live `smbutil statshares -a` showed defaults: signing on,
# change-notify on). /etc/nsmb.conf requires root, so this runs from a root LaunchDaemon
# (net.wind.nsmb-install.plist) at boot — NOT from the user LaunchAgents (which have no sudo).
#
# Idempotent: only copies when content differs. Safe to run repeatedly.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nsmb.conf"
DST="/etc/nsmb.conf"
log(){ echo "$(date '+%F %T') nsmb-install: $*"; }

[ -f "${SRC}" ] || { log "✗ source ${SRC} missing"; exit 1; }
if cmp -s "${SRC}" "${DST}" 2>/dev/null; then
  log "✓ ${DST} already current"; exit 0
fi
if cp "${SRC}" "${DST}" && chmod 644 "${DST}" && chown root:wheel "${DST}"; then
  log "✓ installed ${DST} (remount required for it to take effect)"
  exit 0
fi
log "✗ failed to install ${DST} (run as root?)"
exit 1
