#!/bin/bash
#
# update-route53.sh — Cloudflare DDNS updater
#
# Despite the filename, this script writes to **Cloudflare**, not
# Route53. Migrated 2026-05-27 from aws-cli + Route53 to curl + the
# Cloudflare REST API after the etherport.net Route53 hosted zone was
# deleted as part of the broader DNS-to-CF migration. The script name
# is preserved because the image + Dockerfile + cronjob.yaml + SA all
# reference it; renaming is a follow-up.
#
# Required Environment Variables:
#   CF_ZONE_ID       - Cloudflare zone ID for the target zone
#   CF_API_TOKEN     - CF API token with Zone:DNS:Edit on the zone
#                      (provided via Secret in K8s; see route53-ddns
#                       namespace secret manifest)
#   RECORD_NAMES     - Comma-separated list of DNS record names to keep
#                      in sync with the current public IP
#   TTL              - DNS record TTL in seconds (default: 300)
#
# Optional:
#   IP_DNS_SOURCE    - How to determine the public IP:
#                      "auto" - Auto-detect active WAN by comparing
#                               egress to wan1/wan2 DNS
#                      "<dns_name>" - Resolve specific DNS name
#                      (empty) - Use IP_SERVICE_URL (default behavior)
#   IP_WAN1_DNS      - DNS name for WAN1 (default: wan1.wind.etherport.net)
#   IP_WAN2_DNS      - DNS name for WAN2 (default: wan2.wind.etherport.net)
#   IP_SERVICE_URL   - URL to get public IP (default: https://checkip.amazonaws.com)
#   PUSHGATEWAY_URL  - Prometheus pushgateway URL for metrics
#
# Deprecated (ignored):
#   HOSTED_ZONES, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   Kept readable in configmap/secret as a backout safety net; if
#   anything still references them the script just doesn't use them.

set -euo pipefail

VERSION="2.0.0"  # bumped 2026-05-27 for CF migration

TTL="${TTL:-300}"
IP_SERVICE_URL="${IP_SERVICE_URL:-https://checkip.amazonaws.com}"
IP_DNS_SOURCE="${IP_DNS_SOURCE:-}"
START_EPOCH=$(date +%s)
CF_API="https://api.cloudflare.com/client/v4"

cleanup() {
  rm -f /tmp/cf-resp-*.json /tmp/metrics.txt 2>/dev/null || true
}
trap cleanup EXIT

validate_ip() {
  local ip="$1"
  local IFS='.'
  read -ra octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((octet >= 0 && octet <= 255)) || return 1
  done
  return 0
}

fetch_ip_from_dns() {
  local dns_name="$1"
  local ip
  ip=$(dig +short "$dns_name" @8.8.8.8 2>/dev/null | head -1)
  [[ -n "$ip" ]] && echo "$ip" && return 0
  return 1
}

detect_active_wan_ip() {
  local wan1_dns="${IP_WAN1_DNS:-wan1.wind.etherport.net}"
  local wan2_dns="${IP_WAN2_DNS:-wan2.wind.etherport.net}"
  local wan1_ip wan2_ip egress_ip

  wan1_ip=$(fetch_ip_from_dns "$wan1_dns" 2>/dev/null || echo "")
  wan2_ip=$(fetch_ip_from_dns "$wan2_dns" 2>/dev/null || echo "")
  egress_ip=$(curl -s --max-time 3 "${IP_SERVICE_URL:-https://checkip.amazonaws.com}" 2>/dev/null || echo "")

  echo "  WAN1 ($wan1_dns): ${wan1_ip:-<unresolved>}" >&2
  echo "  WAN2 ($wan2_dns): ${wan2_ip:-<unresolved>}" >&2
  echo "  Egress IP: ${egress_ip:-<unknown>}" >&2

  if [[ -n "$egress_ip" && "$egress_ip" == "$wan1_ip" ]]; then
    echo "  Active WAN: WAN1 (egress matches)" >&2
    echo "$wan1_ip"
    return 0
  elif [[ -n "$egress_ip" && "$egress_ip" == "$wan2_ip" ]]; then
    echo "  Active WAN: WAN2 (egress matches)" >&2
    echo "$wan2_ip"
    return 0
  fi

  if [[ -n "$wan1_ip" ]]; then
    echo "  Active WAN: WAN1 (default primary)" >&2
    echo "$wan1_ip"
    return 0
  elif [[ -n "$wan2_ip" ]]; then
    echo "  Active WAN: WAN2 (wan1 unavailable)" >&2
    echo "$wan2_ip"
    return 0
  fi

  return 1
}

fetch_ip_with_retry() {
  local max_attempts=3
  local delay=1

  if [[ "${IP_DNS_SOURCE:-}" == "auto" ]]; then
    echo "Detecting active WAN..." >&2
    local ip
    ip=$(detect_active_wan_ip) && [[ -n "$ip" ]] && echo "$ip" && return 0
    echo "WARNING: Could not detect active WAN IP" >&2
    return 1
  fi

  if [[ -n "${IP_DNS_SOURCE:-}" ]]; then
    for ((i=1; i<=max_attempts; i++)); do
      local ip
      ip=$(fetch_ip_from_dns "$IP_DNS_SOURCE") && [[ -n "$ip" ]] && echo "$ip" && return 0
      echo "WARNING: DNS lookup attempt $i/$max_attempts failed for $IP_DNS_SOURCE, retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 2))
    done
    return 1
  fi

  for ((i=1; i<=max_attempts; i++)); do
    local ip
    ip=$(curl -s --max-time 3 "$IP_SERVICE_URL" 2>&1) && [[ -n "$ip" ]] && echo "$ip" && return 0
    echo "WARNING: IP fetch attempt $i/$max_attempts failed, retrying in ${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

cf_lookup_record() {
  # Echo "record_id\tcurrent_ip" or empty string if missing.
  local name="$1"
  local resp
  resp=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "${CF_API}/zones/${CF_ZONE_ID}/dns_records?type=A&name=${name}")
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo "ERROR: CF lookup for $name failed: $(echo "$resp" | jq -c '.errors')" >&2
    return 1
  fi
  local rid current
  rid=$(echo "$resp" | jq -r '.result[0].id // empty')
  current=$(echo "$resp" | jq -r '.result[0].content // empty')
  printf "%s\t%s" "$rid" "$current"
}

cf_upsert_record() {
  local name="$1" ip="$2" rid="$3"
  local body
  body=$(jq -n --arg name "$name" --arg ip "$ip" --argjson ttl "$TTL" \
    '{type:"A", name:$name, content:$ip, ttl:$ttl, proxied:false, comment:"Managed by route53-ddns CronJob"}')

  local resp
  if [[ -n "$rid" ]]; then
    resp=$(curl -s -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "${CF_API}/zones/${CF_ZONE_ID}/dns_records/${rid}" -d "$body")
  else
    resp=$(curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "${CF_API}/zones/${CF_ZONE_ID}/dns_records" -d "$body")
  fi
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo "ERROR: CF write for $name failed: $(echo "$resp" | jq -c '.errors')" >&2
    return 1
  fi
  echo "Change ID: $(echo "$resp" | jq -r '.result.id')"
}

# Validate required envs
if [[ -z "${CF_ZONE_ID:-}" ]]; then
  echo "ERROR: CF_ZONE_ID environment variable required" >&2
  exit 1
fi
if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "ERROR: CF_API_TOKEN environment variable required" >&2
  exit 1
fi
if [[ -z "${RECORD_NAMES:-}" ]]; then
  echo "ERROR: RECORD_NAMES environment variable required" >&2
  exit 1
fi

IFS=',' read -ra NAME_ARRAY <<< "$RECORD_NAMES"

echo "======================================"
echo "Cloudflare Dynamic DNS Updater"
echo "======================================"
echo "Time:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Version:     $VERSION"
echo "Zone:        $CF_ZONE_ID"
echo "Records:     ${#NAME_ARRAY[@]}"
echo "TTL:         ${TTL}s"
if [[ "${IP_DNS_SOURCE:-}" == "auto" ]]; then
  echo "IP Source:   Auto-detect active WAN"
elif [[ -n "${IP_DNS_SOURCE:-}" ]]; then
  echo "IP Source:   DNS lookup of ${IP_DNS_SOURCE}"
else
  echo "IP Source:   ${IP_SERVICE_URL}"
fi
echo "======================================"
echo ""

echo "[1/3] Fetching current public IP..."
CURRENT_IP=$(fetch_ip_with_retry)

if [[ -z "$CURRENT_IP" ]]; then
  echo "ERROR: Could not determine current public IP after retries" >&2
  exit 1
fi
if ! validate_ip "$CURRENT_IP"; then
  echo "ERROR: Invalid IP address format: $CURRENT_IP" >&2
  exit 1
fi

echo "Current public IP: $CURRENT_IP"
echo ""

UPDATES_MADE=0
UPDATES_SKIPPED=0
UPDATES_FAILED=0
UPDATED_RECORDS=()

echo "[2/3] Checking and updating DNS records..."
for RECORD_NAME in "${NAME_ARRAY[@]}"; do
  echo "---"
  echo "Processing: $RECORD_NAME"

  lookup=$(cf_lookup_record "$RECORD_NAME" || true)
  RECORD_ID="${lookup%%$'\t'*}"
  EXISTING_IP="${lookup##*$'\t'}"

  echo "Existing IP: ${EXISTING_IP:-<none>}"

  if [[ "$CURRENT_IP" == "$EXISTING_IP" ]]; then
    echo "Status: No change needed (already $CURRENT_IP)"
    UPDATES_SKIPPED=$((UPDATES_SKIPPED + 1))
    continue
  fi

  if cf_upsert_record "$RECORD_NAME" "$CURRENT_IP" "$RECORD_ID"; then
    echo "Status: Updated successfully"
    echo "Change: ${EXISTING_IP:-<none>} → $CURRENT_IP"
    UPDATES_MADE=$((UPDATES_MADE + 1))
    UPDATED_RECORDS+=("$RECORD_NAME")
  else
    echo "ERROR: Failed to update $RECORD_NAME" >&2
    UPDATES_FAILED=$((UPDATES_FAILED + 1))
  fi
done

echo ""
echo "======================================"
echo "Summary"
echo "======================================"
echo "Public IP:       $CURRENT_IP"
echo "Records checked: ${#NAME_ARRAY[@]}"
echo "Updated:         $UPDATES_MADE"
echo "Skipped:         $UPDATES_SKIPPED (no change)"
echo "Failed:          $UPDATES_FAILED"

if [[ $UPDATES_MADE -gt 0 ]]; then
  echo ""
  echo "Updated records:"
  for record in "${UPDATED_RECORDS[@]}"; do
    echo "  - $record → $CURRENT_IP"
  done
fi

echo "======================================"
echo ""

if [[ -n "${PUSHGATEWAY_URL:-}" ]]; then
  echo "[3/3] Pushing metrics to Prometheus..."

  END_EPOCH=$(date +%s)
  DURATION=$((END_EPOCH - START_EPOCH))
  SUCCESS_VAL=$([[ $UPDATES_FAILED -eq 0 ]] && echo 1 || echo 0)

  cat > /tmp/metrics.txt <<METRICS
# HELP route53_ddns_success Whether the DDNS update succeeded
# TYPE route53_ddns_success gauge
route53_ddns_success $SUCCESS_VAL

# HELP route53_ddns_updates_made Number of DNS records updated
# TYPE route53_ddns_updates_made gauge
route53_ddns_updates_made $UPDATES_MADE

# HELP route53_ddns_updates_skipped Number of DNS records skipped (no change)
# TYPE route53_ddns_updates_skipped gauge
route53_ddns_updates_skipped $UPDATES_SKIPPED

# HELP route53_ddns_updates_failed Number of DNS record updates that failed
# TYPE route53_ddns_updates_failed gauge
route53_ddns_updates_failed $UPDATES_FAILED

# HELP route53_ddns_duration_seconds Duration of the update process
# TYPE route53_ddns_duration_seconds gauge
route53_ddns_duration_seconds $DURATION

# HELP route53_ddns_last_run_timestamp Timestamp of last run
# TYPE route53_ddns_last_run_timestamp gauge
route53_ddns_last_run_timestamp $END_EPOCH
METRICS

  if curl -s --data-binary @/tmp/metrics.txt \
      "${PUSHGATEWAY_URL}/metrics/job/route53-ddns/instance/ddns" > /dev/null; then
    echo "Metrics pushed successfully"
  else
    echo "WARNING: Failed to push metrics to $PUSHGATEWAY_URL" >&2
  fi
fi

if [[ $UPDATES_FAILED -gt 0 ]]; then
  echo ""
  echo "ERROR: $UPDATES_FAILED record update(s) failed" >&2
  exit 1
fi

echo "Cloudflare DDNS update complete"
exit 0
