#!/bin/bash
#
# update-route53.sh
#
# Dynamic DNS updater for Route53 - Updates DNS A records with current public IP
#
# Required Environment Variables:
#   HOSTED_ZONES     - Comma-separated list of Route53 hosted zone IDs
#   RECORD_NAMES     - Comma-separated list of DNS record names (matching HOSTED_ZONES order)
#   TTL              - DNS record TTL in seconds (default: 300)
#   AWS_REGION       - AWS region (default: us-west-2)
#
# Optional:
#   IP_DNS_SOURCE    - How to determine the public IP:
#                      "auto" - Auto-detect active WAN by comparing egress to wan1/wan2 DNS
#                      "<dns_name>" - Resolve specific DNS name (e.g., wan1.wind.etherport.net)
#                      (empty) - Use IP_SERVICE_URL (default behavior)
#   IP_WAN1_DNS      - DNS name for WAN1 (default: wan1.wind.etherport.net)
#   IP_WAN2_DNS      - DNS name for WAN2 (default: wan2.wind.etherport.net)
#   IP_SERVICE_URL   - URL to get public IP (default: https://checkip.amazonaws.com)
#                      Only used if IP_DNS_SOURCE is not set
#   PUSHGATEWAY_URL  - Prometheus pushgateway URL for metrics
#

set -euo pipefail

# Script version
VERSION="1.0.1"

# Configuration
TTL="${TTL:-300}"
IP_SERVICE_URL="${IP_SERVICE_URL:-https://checkip.amazonaws.com}"
IP_DNS_SOURCE="${IP_DNS_SOURCE:-}"  # If set, resolve this DNS name instead of using IP_SERVICE_URL
AWS_REGION="${AWS_REGION:-us-west-2}"
START_EPOCH=$(date +%s)

# Cleanup temporary files on exit
cleanup() {
  rm -f /tmp/route53-change-*.json /tmp/metrics.txt 2>/dev/null || true
}
trap cleanup EXIT

# Functions
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
  # Resolve IP from DNS record using external resolver (8.8.8.8)
  local dns_name="$1"
  local ip
  ip=$(dig +short "$dns_name" @8.8.8.8 2>/dev/null | head -1)
  [[ -n "$ip" ]] && echo "$ip" && return 0
  return 1
}

detect_active_wan_ip() {
  # Detect which WAN is active by resolving both wan1 and wan2
  # and comparing to our actual egress IP
  local wan1_dns="${IP_WAN1_DNS:-wan1.wind.etherport.net}"
  local wan2_dns="${IP_WAN2_DNS:-wan2.wind.etherport.net}"

  local wan1_ip wan2_ip egress_ip

  # Get both WAN IPs from DNS
  wan1_ip=$(fetch_ip_from_dns "$wan1_dns" 2>/dev/null || echo "")
  wan2_ip=$(fetch_ip_from_dns "$wan2_dns" 2>/dev/null || echo "")

  # Get our actual egress IP
  egress_ip=$(curl -s --max-time 3 "${IP_SERVICE_URL:-https://checkip.amazonaws.com}" 2>/dev/null || echo "")

  echo "  WAN1 ($wan1_dns): ${wan1_ip:-<unresolved>}" >&2
  echo "  WAN2 ($wan2_dns): ${wan2_ip:-<unresolved>}" >&2
  echo "  Egress IP: ${egress_ip:-<unknown>}" >&2

  # If egress matches wan1 or wan2, use that
  if [[ -n "$egress_ip" && "$egress_ip" == "$wan1_ip" ]]; then
    echo "  Active WAN: WAN1 (egress matches)" >&2
    echo "$wan1_ip"
    return 0
  elif [[ -n "$egress_ip" && "$egress_ip" == "$wan2_ip" ]]; then
    echo "  Active WAN: WAN2 (egress matches)" >&2
    echo "$wan2_ip"
    return 0
  fi

  # If egress doesn't match either (multi-path/load-balanced), prefer wan1
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

  # If IP_DNS_SOURCE is set to "auto", detect active WAN
  if [[ "${IP_DNS_SOURCE:-}" == "auto" ]]; then
    echo "Detecting active WAN..." >&2
    local ip
    ip=$(detect_active_wan_ip) && [[ -n "$ip" ]] && echo "$ip" && return 0
    echo "WARNING: Could not detect active WAN IP" >&2
    return 1
  fi

  # If IP_DNS_SOURCE is set to a specific DNS name, use that
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

  # Default: use HTTP service
  for ((i=1; i<=max_attempts; i++)); do
    local ip
    ip=$(curl -s --max-time 3 "$IP_SERVICE_URL" 2>&1) && [[ -n "$ip" ]] && echo "$ip" && return 0
    echo "WARNING: IP fetch attempt $i/$max_attempts failed, retrying in ${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

# Validate required environment variables
if [[ -z "${HOSTED_ZONES:-}" ]]; then
  echo "ERROR: HOSTED_ZONES environment variable required" >&2
  exit 1
fi

if [[ -z "${RECORD_NAMES:-}" ]]; then
  echo "ERROR: RECORD_NAMES environment variable required" >&2
  exit 1
fi

# Convert comma-separated strings to arrays
IFS=',' read -ra ZONE_ARRAY <<< "$HOSTED_ZONES"
IFS=',' read -ra NAME_ARRAY <<< "$RECORD_NAMES"

# Validate arrays have same length
if [[ ${#ZONE_ARRAY[@]} -ne ${#NAME_ARRAY[@]} ]]; then
  echo "ERROR: HOSTED_ZONES and RECORD_NAMES must have same number of entries" >&2
  exit 1
fi

echo "======================================"
echo "Route53 Dynamic DNS Updater"
echo "======================================"
echo "Time:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Zones:       ${#ZONE_ARRAY[@]}"
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

# Get current public IP with retry
echo "[1/3] Fetching current public IP..."
CURRENT_IP=$(fetch_ip_with_retry)

if [[ -z "$CURRENT_IP" ]]; then
  echo "ERROR: Could not determine current public IP from $IP_SERVICE_URL after retries" >&2
  exit 1
fi

# Validate IP format (proper octet validation)
if ! validate_ip "$CURRENT_IP"; then
  echo "ERROR: Invalid IP address format: $CURRENT_IP" >&2
  exit 1
fi

echo "Current public IP: $CURRENT_IP"
echo ""

# Track updates
UPDATES_MADE=0
UPDATES_SKIPPED=0
UPDATES_FAILED=0
UPDATED_RECORDS=()

# Process each zone/record pair
echo "[2/3] Checking and updating DNS records..."
for idx in "${!ZONE_ARRAY[@]}"; do
  HOSTED_ZONE_ID="${ZONE_ARRAY[$idx]}"
  RECORD_NAME="${NAME_ARRAY[$idx]}"

  echo "---"
  echo "Processing: $RECORD_NAME (zone: $HOSTED_ZONE_ID)"

  # Get existing record value (optimized: start at our record, fetch only 1)
  EXISTING_IP=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --start-record-name "${RECORD_NAME}." \
    --start-record-type A \
    --max-items 1 \
    --query "ResourceRecordSets[?Name == '${RECORD_NAME}.'].ResourceRecords[0].Value" \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "")

  echo "Existing IP: ${EXISTING_IP:-<none>}"

  # Check if update needed
  if [[ "$CURRENT_IP" == "$EXISTING_IP" ]]; then
    echo "Status: No change needed (already $CURRENT_IP)"
    UPDATES_SKIPPED=$((UPDATES_SKIPPED + 1))
    continue
  fi

  # Build change batch JSON (using jq for safe construction)
  CHANGE_BATCH=$(jq -n \
    --arg name "$RECORD_NAME" \
    --arg ip "$CURRENT_IP" \
    --argjson ttl "$TTL" \
    --arg comment "DDNS update at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      Comment: $comment,
      Changes: [{
        Action: "UPSERT",
        ResourceRecordSet: {
          Name: $name,
          Type: "A",
          TTL: $ttl,
          ResourceRecords: [{Value: $ip}]
        }
      }]
    }'
  )

  # Apply the change
  if aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "$CHANGE_BATCH" \
      --region "$AWS_REGION" \
      --output json > /tmp/route53-change-$idx.json 2>&1; then

    CHANGE_ID=$(jq -r '.ChangeInfo.Id' /tmp/route53-change-$idx.json)
    echo "Status: Updated successfully (Change ID: $CHANGE_ID)"
    echo "Change: $EXISTING_IP → $CURRENT_IP"
    UPDATES_MADE=$((UPDATES_MADE + 1))
    UPDATED_RECORDS+=("$RECORD_NAME")
  else
    echo "ERROR: Failed to update $RECORD_NAME" >&2
    cat /tmp/route53-change-$idx.json >&2
    UPDATES_FAILED=$((UPDATES_FAILED + 1))
  fi

done

echo ""
echo "======================================"
echo "Summary"
echo "======================================"
echo "Public IP:       $CURRENT_IP"
echo "Records checked: ${#ZONE_ARRAY[@]}"
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

# Push metrics to Prometheus (optional)
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

# Exit with error if any updates failed
if [[ $UPDATES_FAILED -gt 0 ]]; then
  echo ""
  echo "ERROR: $UPDATES_FAILED record update(s) failed" >&2
  exit 1
fi

echo "Route53 DDNS update complete"
exit 0
