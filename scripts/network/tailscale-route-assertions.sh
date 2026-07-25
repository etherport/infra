#!/usr/bin/env bash
# Tailscale subnet-route invariants (M153, after the M149 primary-steal incident).
#
# The tailnet control plane RE-ELECTS the subnet-route primary on every advertiser
# change with a fixed preference (vpn-aws > vpn-fallback > k8s-homelab-router) and
# never fails back — so the K8s Connector only routes 10.10.192.0/19 while it is
# the SOLE advertiser. A standby quietly re-advertising the /19 (e.g. an ansible
# re-run of the retired failover config — M150) silently hairpins every TS client
# through AWS, or blackholes the MetalLB VIPs via vpn-fallback (VLAN-201 BGP gap).
# That ran undetected for ~3 days; these assertions make it a same-day alert.
#
# Requires: TS_OAUTH_CLIENT_ID / TS_OAUTH_CLIENT_SECRET in the environment
# (the `wind-infra-ops` OAuth client; SOPS: infra/ansible/playbooks/secrets/
# tailscale-oauth.sops.yaml). Read-only: mints a token, GETs the device list.
#
# Exit 0 = all invariants hold; non-zero = drift (or API failure — conservative).

set -uo pipefail

: "${TS_OAUTH_CLIENT_ID:?TS_OAUTH_CLIENT_ID not set}"
: "${TS_OAUTH_CLIENT_SECRET:?TS_OAUTH_CLIENT_SECRET not set}"

TOKEN=$(curl -fsS --max-time 30 \
  -d "client_id=${TS_OAUTH_CLIENT_ID}" -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
  https://api.tailscale.com/api/v2/oauth/token | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["access_token"])') || {
  echo "FAIL: could not mint a Tailscale OAuth token"; exit 2; }

DEVICES=$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=all") || {
  echo "FAIL: could not fetch the tailnet device list"; exit 2; }

DEVICES_JSON="$DEVICES" python3 - <<'EOF'
import json, os, sys
from datetime import datetime, timezone, timedelta

HOMELAB = "10.10.192.0/19"
AWS     = "10.10.100.0/22"
EXIT    = {"0.0.0.0/0", "::/0"}
ROUTER  = "k8s-homelab-router"

devices = json.loads(os.environ["DEVICES_JSON"])["devices"]
by_host = {d.get("hostname", "?"): d for d in devices}
fails = []


def subnet_routes(d, key):
    return {r for r in (d.get(key) or []) if r not in EXIT}


# A1: the K8s Connector advertises AND has enabled the /19.
router = by_host.get(ROUTER)
if router is None:
    fails.append(f"{ROUTER} is not in the tailnet device list")
else:
    if HOMELAB not in (router.get("advertisedRoutes") or []):
        fails.append(f"{ROUTER} no longer ADVERTISES {HOMELAB}")
    if HOMELAB not in (router.get("enabledRoutes") or []):
        fails.append(f"{ROUTER} does not have {HOMELAB} ENABLED (approval lost?)")
    # A2: the always-on router must be online — if it's gone, remote TS access is down.
    seen = datetime.fromisoformat(router.get("lastSeen", "1970-01-01T00:00:00Z").replace("Z", "+00:00"))
    if datetime.now(timezone.utc) - seen > timedelta(minutes=10):
        fails.append(f"{ROUTER} lastSeen {router.get('lastSeen')} (>10m ago — subnet router offline?)")

# A3: NOBODY ELSE advertises or holds the /19 (sole-advertiser invariant).
for d in devices:
    h = d.get("hostname", "?")
    if h == ROUTER:
        continue
    for key in ("advertisedRoutes", "enabledRoutes"):
        if HOMELAB in (d.get(key) or []):
            fails.append(f"{h} has {HOMELAB} in {key} — WILL steal primary (M149 preemption)")

# A4: vpn-aws routes exactly the AWS /22 (plus exit-node), nothing more.
aws = by_host.get("vpn-aws")
if aws is not None:
    extra = subnet_routes(aws, "enabledRoutes") - {AWS}
    if extra:
        fails.append(f"vpn-aws has unexpected enabled routes: {sorted(extra)}")

# A5: vpn-fallback is exit-node-only (no subnet routes).
fb = by_host.get("vpn-fallback")
if fb is not None:
    extra = subnet_routes(fb, "enabledRoutes")
    if extra:
        fails.append(f"vpn-fallback has subnet routes enabled: {sorted(extra)} (must be exit-only)")

if fails:
    print("TAILSCALE ROUTE DRIFT:")
    for f in fails:
        print(f"  FAIL: {f}")
    sys.exit(1)

print(f"OK: {ROUTER} is the sole {HOMELAB} advertiser+holder and online; "
      f"vpn-aws={AWS} only; vpn-fallback exit-only.")
EOF
