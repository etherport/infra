#!/usr/bin/env bash
# Network/infra safety check — run BEFORE and AFTER any risky change to
# verify we haven't broken anything visible.
#
# Exits 0 if all checks pass, non-zero if anything regresses. Used as a
# guard around UniFi-as-code TF imports + applies, K8s changes, DNS edits,
# anything network-adjacent.
#
# Usage:
#   ./scripts/network/safety-check.sh                # one-shot
#   ./scripts/network/safety-check.sh > /tmp/pre.log
#   diff /tmp/pre.log /tmp/post.log                  # before/after compare

set -uo pipefail

PASS=0
FAIL=0
declare -a fails

run_check() {
  local name="$1"
  local cmd="$2"
  printf "%-50s" "$name"
  if eval "$cmd" >/dev/null 2>&1; then
    echo "✓"
    PASS=$((PASS + 1))
  else
    echo "✗"
    FAIL=$((FAIL + 1))
    fails+=("$name")
  fi
}

echo "=== Network / Infra Safety Check ==="
echo "$(date)"
echo ""

# Layer 1: UDM reachable
run_check "UDM ping (10.10.200.1)" \
  "ping -c 2 -W 2 10.10.200.1"
run_check "UDM HTTPS responding" \
  "curl -sk --max-time 5 https://10.10.200.1 -o /dev/null -w '%{http_code}' | grep -qE '^(200|301|302|404)$'"

# Layer 2: Internal DNS (homelab + AWS replicas)
# WireGuard pushes 10.10.100.5 (AWS) first, then 10.10.201.5/.6 (homelab) —
# all three must resolve internal records identically. See
# platform/wireguard/clients/graham-tcp.conf.template for the rationale.
run_check "DNS @.5 resolves k8s-cp1" \
  "[ \"\$(dig @10.10.201.5 +short +timeout=2 k8s-cp1.wind.etherport.net)\" = '10.10.201.50' ]"
run_check "DNS @.6 resolves k8s-cp1" \
  "[ \"\$(dig @10.10.201.6 +short +timeout=2 k8s-cp1.wind.etherport.net)\" = '10.10.201.50' ]"
run_check "DNS @100.5 (AWS) resolves k8s-cp1" \
  "[ \"\$(dig @10.10.100.5 +short +timeout=2 k8s-cp1.wind.etherport.net)\" = '10.10.201.50' ]"
run_check "DNS @.5 resolves gw" \
  "[ \"\$(dig @10.10.201.5 +short +timeout=2 gw.wind.etherport.net)\" = '10.10.200.1' ]"

# Layer 3: External DNS (Route53 + DDNS)
run_check "External DNS @1.1.1.1 has wan1" \
  "dig @1.1.1.1 +short +timeout=3 wan1.wind.etherport.net | grep -qE '^[0-9]+\\.'"
run_check "External DNS @1.1.1.1 has apex" \
  "dig @1.1.1.1 +short +timeout=3 wind.etherport.net | grep -qE '^[0-9]+\\.'"

# Layer 4: K8s cluster
run_check "K8s API reachable" \
  "kubectl --request-timeout=5s get nodes -o name 2>/dev/null | grep -q k8s"
run_check "K8s all nodes Ready" \
  "[ \"\$(kubectl --request-timeout=5s get nodes -o json 2>/dev/null | jq -r '.items[].status.conditions[] | select(.type==\"Ready\") | .status' | sort -u)\" = 'True' ]"
run_check "Flux Kustomization Ready" \
  "kubectl --request-timeout=5s -n flux-system get kustomization flux-system -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

# Layer 5: Critical services
# Traefik VIP doesn't respond to ICMP by design — check HTTPS instead
run_check "Traefik VIP HTTPS responding" \
  "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://10.10.201.70 | grep -qE '^(200|301|302|404|405)$'"
run_check "K8s WireGuard VIP reachable" \
  "ping -c 3 -W 5 10.10.201.20"
run_check "dns-fallback (.6) reachable" \
  "ping -c 3 -W 5 10.10.201.6"
run_check "vpn-local (.15) reachable" \
  "ping -c 3 -W 5 10.10.201.15"
run_check "gh-runner (.30) reachable" \
  "ping -c 3 -W 5 10.10.201.30"
run_check "Proxmox (200.41) reachable" \
  "ping -c 3 -W 5 10.10.200.41"
run_check "Sequoia NAS (209.10) reachable" \
  "ping -c 3 -W 5 10.10.209.10"

# Layer 6: UniFi API (proves tf-admin still works, dump-state still works)
run_check "UDM API: tf-admin auth still works" \
  "test -s /tmp/unifi-state/.cookies && curl -sk --max-time 5 -b /tmp/unifi-state/.cookies -H \"X-CSRF-Token: \$(cat /tmp/unifi-state/.csrf)\" 'https://10.10.200.1/proxy/network/api/s/default/rest/networkconf' | jq -e '.data | length > 0' >/dev/null"
# UniFi adopted devices (UDM, switches, APs) all connected (state == 1).
# Skips silently if no cached cookies — `scripts/unifi/dump-state.sh` refreshes them.
run_check "UniFi adopted devices all connected" \
  "test -s /tmp/unifi-state/.cookies && curl -sk --max-time 5 -b /tmp/unifi-state/.cookies -H \"X-CSRF-Token: \$(cat /tmp/unifi-state/.csrf)\" 'https://10.10.200.1/proxy/network/api/s/default/stat/device' | jq -e '[.data[] | select(.adopted == true) | .state] | length > 0 and all(. == 1)' >/dev/null"

# Layer 7: Storage (Ceph). The Ceph mon at 10.10.210.41 lives on the
# dedicated storage VLAN 210 which is intentionally NOT routed to clients
# or WG users — so ICMP from the laptop won't reach it. Instead, verify
# the K8s ceph-csi configmap points at the correct mon IP. A regression
# here means a kustomize/Flux mistake re-introduced the old .201.41 IP
# (caught 2026-05-18 during the VLAN-210 Ceph migration).
run_check "ceph-csi mon IP is 210.41 (storage VLAN)" \
  "kubectl --request-timeout=5s -n default get cm ceph-csi-config -o jsonpath='{.data.config\\.json}' 2>/dev/null | grep -q '10.10.210.41:6789'"

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "FAILURES:"
  for f in "${fails[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
