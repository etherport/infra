#!/usr/bin/env bash
# Mint a short-lived (1h) GitHub App INSTALLATION token.
#
# WHY: user-scoped PATs cannot see repos in the `etherport` org (they 404), and
# they expire on a schedule that has to be babysat. A GitHub App authenticates
# with a private key that does NOT expire, minting 1h installation tokens on
# demand — no rotation treadmill, and each call can be scoped down to only the
# permissions/repos it needs. See docs/planning/github-org-migration-2026-08.md
# (Phase 2).
#
# Flow: build a <=10min RS256 JWT signed with the App private key (authenticates
# AS THE APP) -> POST /app/installations/<id>/access_tokens -> installation token
# (authenticates AS THE INSTALLATION, i.e. what you use like a PAT).
#
# Usage:
#   gh-app-token.sh                                  # full installation scope
#   gh-app-token.sh --permissions '{"contents":"read"}'
#   gh-app-token.sh --repositories '["infra","cue"]'
#   Prints ONLY the token to stdout (diagnostics go to stderr) so callers can do:
#     TOKEN="$(scripts/gh-app-token.sh --permissions '{"actions":"write"}')"
#
# Config (env, or the SOPS bundle via --from-sops):
#   GH_APP_ID              numeric App ID
#   GH_APP_INSTALLATION_ID numeric Installation ID
#   GH_APP_PRIVATE_KEY     PEM contents  (or GH_APP_PRIVATE_KEY_FILE = path)
set -euo pipefail

API="${GH_API:-https://api.github.com}"
PERMS=""; REPOS=""; FROM_SOPS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --permissions)  PERMS="$2"; shift 2 ;;
    --repositories) REPOS="$2"; shift 2 ;;
    --from-sops)    FROM_SOPS=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Pull creds from the SOPS bundle when asked (devbox has the age key).
if [ "$FROM_SOPS" = "1" ]; then
  BUNDLE="${GH_APP_SOPS_FILE:-$(dirname "$0")/../infra/ansible/playbooks/secrets/homelab-ops.sops.yaml}"
  # Parse as YAML, not sed: the PEM is a multi-line block scalar and (being the
  # last key in the bundle) has no terminating `^key:` line, which silently ate
  # the -----END----- line off a sed range and produced an unreadable key.
  eval "$(sops -d "$BUNDLE" | python3 -c '
import sys, yaml, shlex
d = yaml.safe_load(sys.stdin) or {}
for var, key in (("GH_APP_ID","github_app_id"),
                 ("GH_APP_INSTALLATION_ID","github_app_installation_id"),
                 ("GH_APP_PRIVATE_KEY","github_app_private_key")):
    v = d.get(key)
    if v is not None:
        print(f"{var}=${{{var}:-{shlex.quote(str(v))}}}")
')"
fi

: "${GH_APP_ID:?GH_APP_ID required}"
: "${GH_APP_INSTALLATION_ID:?GH_APP_INSTALLATION_ID required}"
if [ -z "${GH_APP_PRIVATE_KEY:-}" ] && [ -n "${GH_APP_PRIVATE_KEY_FILE:-}" ]; then
  GH_APP_PRIVATE_KEY="$(cat "$GH_APP_PRIVATE_KEY_FILE")"
fi
: "${GH_APP_PRIVATE_KEY:?GH_APP_PRIVATE_KEY or GH_APP_PRIVATE_KEY_FILE required}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
# iat backdated 60s to tolerate clock skew; exp well under GitHub's 10min ceiling.
header='{"alg":"RS256","typ":"JWT"}'
payload="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"${GH_APP_ID}\"}"
unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"

keyfile="$(mktemp)"; trap 'rm -f "$keyfile"' EXIT
printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$keyfile"
sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$keyfile" | b64url)"
jwt="${unsigned}.${sig}"

body="{}"
if [ -n "$PERMS" ] && [ -n "$REPOS" ]; then
  body="{\"permissions\":${PERMS},\"repositories\":${REPOS}}"
elif [ -n "$PERMS" ]; then
  body="{\"permissions\":${PERMS}}"
elif [ -n "$REPOS" ]; then
  body="{\"repositories\":${REPOS}}"
fi

resp="$(curl -sS --max-time 30 -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$body" \
  "${API}/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens")"

token="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
if [ -z "$token" ]; then
  # never echo the raw response blind — it can contain a token on partial failure
  echo "gh-app-token: FAILED to mint installation token" >&2
  printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  message:", d.get("message"), "| status:", d.get("status"), file=sys.stderr)' 2>/dev/null || echo "  (unparseable response)" >&2
  exit 1
fi
printf '%s\n' "$token"
