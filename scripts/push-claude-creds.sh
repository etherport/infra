#!/usr/bin/env bash
# Push this laptop's Claude Code subscription credentials to the dev box.
#
# WHY: Claude Code's remote-control feature needs a subscription login carrying
# the `user:sessions:claude_code` scope. The INTERACTIVE OAuth login is broken on
# headless Linux on every build we tried ("Missing code_challenge" PKCE on new
# builds; "Invalid OAuth Request" / stale client_id on old builds). So instead of
# logging in on the box, we copy this (already-authenticated) laptop's creds over.
#
# This laptop stores them in the macOS Keychain (item "Claude Code-credentials");
# Linux stores the same JSON at ~/.claude/.credentials.json. The token auto-
# refreshes, so a one-shot copy persists — re-run only after a box rebuild or if
# the box gets logged out.
#
# Run on the LAPTOP (where Claude Code is logged in). Requires: tailscale/SSH to
# the box. The token never touches disk in plaintext beyond the encrypted SSH pipe.
#
#   scripts/push-claude-creds.sh [user@host]   # default: ubuntu@100.74.216.102
set -euo pipefail

BOX="${1:-ubuntu@100.74.216.102}"
KEYCHAIN_ITEM="Claude Code-credentials"

creds="$(security find-generic-password -s "$KEYCHAIN_ITEM" -w 2>/dev/null || true)"
if [ -z "$creds" ]; then
  echo "ERROR: no '$KEYCHAIN_ITEM' in the login Keychain — is Claude Code logged in on this laptop?" >&2
  exit 1
fi

# Sanity-check the scope locally (no token printed).
echo "$creds" | python3 -c '
import json,sys
d=json.load(sys.stdin)["claudeAiOauth"]
assert "user:sessions:claude_code" in d["scopes"], "creds lack the sessions scope remote control needs"
print(f"laptop creds OK — sub: {d[\"subscriptionType\"]}, scopes: {d[\"scopes\"]}")
'

printf '%s' "$creds" | ssh -o ConnectTimeout=10 "$BOX" \
  'mkdir -p ~/.claude && cat > ~/.claude/.credentials.json && chmod 600 ~/.claude/.credentials.json && \
   python3 -c "import json;d=json.load(open(\"/home/ubuntu/.claude/.credentials.json\"))[\"claudeAiOauth\"];print(\"box creds installed — scopes:\",d[\"scopes\"])"'

echo "Done. Test on the box:  claude --remote-control \"devbox\""
