#!/bin/bash
# Print the iCloud app-specific password to stdout, decrypted from the SOPS bundle (the mini
# holds the age key, so this works headlessly). Used by vdirsyncer's password.fetch (M80).
#
# One-time: add the secret to the bundle (interactively, the value never touches this repo):
#   sops infra/ansible/playbooks/secrets/homelab-ops.sops.yaml
#   # add a top-level line:  icloud_app_password: xxxx-xxxx-xxxx-xxxx   (from appleid.apple.com)
# Resolve sops by FULL PATH — launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) excludes
# Homebrew's /opt/homebrew/bin, so a bare `sops` is "not found" (rc=127) under the LaunchAgent
# even though it works in an interactive shell. That silently broke every launchd DAV run (no
# password → vdirsyncer auth fail → rc=1) while manual runs succeeded. (Found 2026-06-24.)
SOPS="${SOPS:-$(command -v sops 2>/dev/null)}"
if [ -z "${SOPS}" ]; then
  for p in /opt/homebrew/bin/sops /usr/local/bin/sops /usr/bin/sops; do [ -x "$p" ] && SOPS="$p" && break; done
fi
# Point sops at the age key explicitly: launchd does NOT inherit the interactive shell's
# SOPS_AGE_KEY_FILE export, and sops' default-location lookup failed under the LaunchAgent
# ("failed to load age identities") — so a manual run decrypted fine but every launchd run got
# no password → vdirsyncer auth fail → rc=1. (Found 2026-06-24, with the sops-PATH bug above.)
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
exec "${SOPS:-sops}" -d --extract '["icloud_app_password"]' \
  /Users/grahamsmith/code/infra/infra/ansible/playbooks/secrets/homelab-ops.sops.yaml
