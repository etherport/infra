#!/usr/bin/env bash
# Network-topology invariant assertions — catches the "201-class" drift.
#
# WHY: routing/zone facts (e.g. "Servers/201's gateway is the UDM") are NOT a
# live-vs-IaC diff, so neither terraform-drift-detection.yml nor
# ansible-drift-detection.yml can catch them. The 2026-06-29 "201 is switch-routed"
# doc error was exactly this class — the docs AND the IaC carried a stale premise and
# only a live `ip route` probe revealed the truth. This script encodes those probes as
# assertions so the same drift is caught automatically.
#
# RUN FROM A VLAN-201 HOST (the gh-runner/lifecycle VM @ 10.10.201.30 qualifies; so does
# the devbox @ .45). It reads the HOST routing table, so the CI job must NOT run in a
# container (a container has its own netns). Exits non-zero + lists the failed assertion(s)
# on drift; prints all PASS lines on success.
#
# Authoritative model (see docs/architecture/firewall-zones.md): Servers/201 is FULLY
# UDM-routed since M56/BGP — every off-201 inter-VLAN destination + the internet first-hops
# the UDM 10.10.201.1. If 201 ever moves back to switch-routed (or the gateway changes), the
# first-hop changes and these assertions fail.
set -uo pipefail

UDM="10.10.201.1"
fail=0

first_hop() { ip route get "$1" 2>/dev/null | grep -oE 'via [0-9.]+' | head -1 | awk '{print $2}'; }

assert_via() { # dst expected_gw label
  local dst="$1" gw="$2" label="$3" hop
  hop="$(first_hop "$dst")"
  if [ "$hop" = "$gw" ]; then
    echo "PASS: $label ($dst -> via $hop)"
  else
    echo "FAIL: $label ($dst -> via '${hop:-<none>}', expected $gw)"
    fail=1
  fi
}

echo "# topology assertions from $(hostname) [$(first_hop "$UDM" >/dev/null 2>&1; ip -br addr show 2>/dev/null | awk '/10\.10\.201\./{print $3; exit}')]"

# Servers/201 is UDM-routed: off-201 inter-VLAN dests + internet first-hop the UDM.
assert_via "10.10.202.1"  "$UDM" "201->Clients/202 via UDM"
assert_via "10.10.209.10" "$UDM" "201->vSAN/209 via UDM"
assert_via "10.10.210.41" "$UDM" "201->Ceph/210 via UDM"
assert_via "10.10.204.1"  "$UDM" "201->IoT/204 via UDM"
assert_via "8.8.8.8"      "$UDM" "201->internet via UDM"

# Default route is the UDM.
defgw="$(ip route show default 2>/dev/null | grep -oE 'via [0-9.]+' | head -1 | awk '{print $2}')"
if [ "$defgw" = "$UDM" ]; then
  echo "PASS: default route via UDM ($defgw)"
else
  echo "FAIL: default route via '${defgw:-<none>}', expected $UDM"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "TOPOLOGY DRIFT: a routing invariant changed. Either 201's gateway moved (e.g. back to"
  echo "switch-routed) or a route was added/removed. Re-verify against docs/architecture/firewall-zones.md"
  echo "and the live UDM config; update both if the change is intentional."
fi
exit "$fail"
