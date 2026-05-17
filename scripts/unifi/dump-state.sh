#!/usr/bin/env bash
# Dump current UniFi Network controller state to JSON for Terraform import.
#
# Pulls credentials from 1Password at runtime (no plaintext on disk), authenticates
# against the UDM, and writes one JSON file per resource type to OUT_DIR.
#
# Usage:
#   scripts/unifi/dump-state.sh                       # defaults: UDM 10.10.200.1, OUT_DIR /tmp/unifi-state
#   UDM_HOST=gw.wind.etherport.net ./dump-state.sh    # override host
#   OUT_DIR=/tmp/unifi-snap ./dump-state.sh            # override output dir
#
# Prereqs:
#   - op (1Password CLI), authenticated (`op signin` or biometric)
#   - curl, jq
#   - L3 reach to the UDM (homelab VPN or LAN-attached)
#
# The 1Password item ID below points to "Windroute (tf-admin)" in the Private vault.
# Override with TFADMIN_OP_ITEM=<id-or-title> if you've renamed the item.

set -euo pipefail

UDM_HOST="${UDM_HOST:-10.10.200.1}"
OUT_DIR="${OUT_DIR:-/tmp/unifi-state}"
TFADMIN_OP_ITEM="${TFADMIN_OP_ITEM:-di4fnt6r4q5j4ddeoazojetg6m}"
TFADMIN_OP_VAULT="${TFADMIN_OP_VAULT:-Private}"
SITE="${SITE:-default}"

COOKIE_JAR="${OUT_DIR}/.cookies"
CSRF_FILE="${OUT_DIR}/.csrf"

# NB: do not use USERNAME — macOS sets it as a read-only env var
fetch_creds() {
  echo "==> Fetching tf-admin creds from 1Password item ${TFADMIN_OP_ITEM}" >&2
  local json
  json=$(op item get "${TFADMIN_OP_ITEM}" --vault "${TFADMIN_OP_VAULT}" --format=json)
  TF_USER=$(echo "${json}" | jq -r '.fields[] | select(.label=="username") | .value')
  TF_PASS=$(echo "${json}" | jq -r '.fields[] | select(.label=="password") | .value')
  if [[ -z "${TF_USER}" || -z "${TF_PASS}" ]]; then
    echo "ERROR: empty credentials returned from 1Password" >&2
    exit 1
  fi
}

login() {
  echo "==> Authenticating to https://${UDM_HOST}/api/auth/login as ${TF_USER}" >&2
  local http_status
  http_status=$(curl -sk -o "${OUT_DIR}/.login-body" -w '%{http_code}' \
    -X POST "https://${UDM_HOST}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${TF_USER}\",\"password\":\"${TF_PASS}\"}" \
    -c "${COOKIE_JAR}" \
    -D "${OUT_DIR}/.login-headers")
  if [[ "${http_status}" != "200" ]]; then
    echo "ERROR: auth failed (HTTP ${http_status})" >&2
    head -c 500 "${OUT_DIR}/.login-body" >&2
    exit 1
  fi
  grep -i "^x-csrf-token:" "${OUT_DIR}/.login-headers" | awk '{print $2}' | tr -d '\r\n' > "${CSRF_FILE}"
  echo "    auth ok, csrf cached" >&2
}

api_get() {
  local path="$1"
  local out="$2"
  local csrf
  csrf=$(<"${CSRF_FILE}")
  curl -sk \
    -b "${COOKIE_JAR}" \
    -H "X-CSRF-Token: ${csrf}" \
    "https://${UDM_HOST}${path}" \
  | jq '.' > "${out}"
  # Some endpoints return `{data: [...]}`, v2 endpoints return a bare array.
  local n
  n=$(jq 'if type=="array" then length else (.data | length // 0) end' < "${out}" 2>/dev/null || echo 0)
  echo "    GET ${path} -> ${out} (${n} items)" >&2
}

main() {
  mkdir -p "${OUT_DIR}"
  fetch_creds
  login

  echo "==> Dumping UniFi state to ${OUT_DIR}" >&2
  # Core resources (Phase 1 import targets)
  api_get "/proxy/network/api/s/${SITE}/rest/networkconf"     "${OUT_DIR}/networks.json"
  api_get "/proxy/network/api/s/${SITE}/rest/portforward"     "${OUT_DIR}/port-forwards.json"
  api_get "/proxy/network/api/s/${SITE}/rest/user"            "${OUT_DIR}/users.json"
  api_get "/proxy/network/api/s/${SITE}/rest/firewallgroup"   "${OUT_DIR}/firewall-groups.json"
  api_get "/proxy/network/api/s/${SITE}/rest/firewallrule"    "${OUT_DIR}/firewall-rules.json"
  api_get "/proxy/network/api/s/${SITE}/stat/sites"           "${OUT_DIR}/sites.json"
  # Routes + switch port profiles + per-device config + v10 zone-based
  # firewall. The v10 zone-matrix firewall lives at v2/api/site, NOT
  # under rest/firewallrule (which is empty in v10). Added 2026-05-17.
  api_get "/proxy/network/api/s/${SITE}/rest/routing"            "${OUT_DIR}/routing.json"
  api_get "/proxy/network/api/s/${SITE}/rest/portconf"           "${OUT_DIR}/port-profiles.json"
  api_get "/proxy/network/api/s/${SITE}/stat/device"             "${OUT_DIR}/devices.json"
  api_get "/proxy/network/v2/api/site/${SITE}/firewall-policies" "${OUT_DIR}/firewall-policies.json"
  # firewall-zones endpoint not yet discovered on UniFi Network 10.3.58 —
  # the v2/api/.../firewall-zones path returns 404. Zone IDs are derivable
  # from firewall-policies (source.zone_id + destination.zone_id) for now.

  # Derived view: only fixed-IP users (the candidates for unifi_user imports).
  jq '{data: [.data[] | select(.use_fixedip == true)]}' \
    "${OUT_DIR}/users.json" > "${OUT_DIR}/users-fixed-ip.json"
  local n
  n=$(jq '.data | length' < "${OUT_DIR}/users-fixed-ip.json")
  echo "    derived users-fixed-ip.json (${n} fixed-IP users)" >&2

  # Cleanup transient files
  rm -f "${OUT_DIR}/.login-body" "${OUT_DIR}/.login-headers"
  chmod 600 "${COOKIE_JAR}" "${CSRF_FILE}"

  echo "" >&2
  echo "==> Done. Snapshot at ${OUT_DIR}" >&2
  echo "    Files:" >&2
  ls -la "${OUT_DIR}" | tail -n +2 | sed 's/^/      /' >&2
}

main "$@"
