#!/usr/bin/env bash
# step-ca PKI health + CA-cert expiry assertions (drift detector #3).
#
# WHY: the fleet is SSH cert-only (M76) and internal TLS is step-ca-issued. Leaf certs are
# SHORT-LIVED + auto-renewed (devbox 13h, CI <=1h), so they're not the risk — the risk is the
# renewal PIPELINE silently breaking, or a long-lived TRUST ANCHOR (root / intermediate CA)
# marching toward expiry unnoticed. Either ends in a fleet-wide lockout (break-glass = PVE
# console + IPMI). Health/expiry alerting on step-ca itself is the missing piece.
#
# Run from a host that can reach step-ca (VM 1006 @ 10.10.201.46:8443 on VLAN 201; the
# lifecycle runner + devbox qualify). Needs curl + openssl. Exits non-zero + lists failures.
set -uo pipefail

STEPCA="${STEPCA:-10.10.201.46:8443}"
MIN_DAYS="${MIN_DAYS:-30}"          # warn if any CA cert has fewer than this many days left
ROOT_PEM="${ROOT_PEM:-infra/terraform/aws/roles-anywhere/step-ca-root.pem}"  # committed trust anchor
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

now="$(date +%s)"
days_left() { # pem-file -> integer days until NotAfter (or empty on parse error)
  local end; end="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2)"
  [ -z "$end" ] && return 1
  echo "$(( ( $(date -d "$end" +%s 2>/dev/null) - now ) / 86400 ))"
}

# 1) step-ca is up + healthy.
health="$(curl -sk --max-time 10 "https://${STEPCA}/health" 2>/dev/null)"
case "$health" in
  *'"status":"ok"'*) ok "step-ca /health = ok" ;;
  *) bad "step-ca /health = '${health:-<unreachable>}' (CA down -> renewals stop -> eventual fleet lockout)" ;;
esac

# 2) CA certs in the served chain (intermediate) — expiry margin. The short-lived LEAF
#    (step-ca's own serving cert) is correctly skipped (basicConstraints CA:TRUE filter).
tmp="$(mktemp -d)"
if echo | openssl s_client -connect "$STEPCA" -showcerts 2>/dev/null > "$tmp/chain.out" && [ -s "$tmp/chain.out" ]; then
  csplit -sz -f "$tmp/c-" -b '%02d.pem' "$tmp/chain.out" '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true
  seen_ca=0
  for f in "$tmp"/c-*.pem; do
    openssl x509 -in "$f" -noout >/dev/null 2>&1 || continue
    [ "$(openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null | grep -c 'CA:TRUE')" -gt 0 ] || continue
    seen_ca=1
    subj="$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/subject=//;s/^ *//')"
    d="$(days_left "$f")"
    if [ -n "$d" ] && [ "$d" -ge "$MIN_DAYS" ]; then ok "served CA cert ${d}d left — $subj"
    else bad "served CA cert ${d:-?}d left (< ${MIN_DAYS}d) — $subj — ROTATE the intermediate CA"; fi
  done
  [ "$seen_ca" -eq 0 ] && bad "no CA cert found in the step-ca served chain (unexpected)"
else
  bad "could not fetch the step-ca cert chain from $STEPCA"
fi
rm -rf "$tmp"

# 3) The committed ROOT trust anchor — catastrophic if it expires (everything trusts it).
if [ -f "$ROOT_PEM" ]; then
  d="$(days_left "$ROOT_PEM")"
  if [ -n "$d" ] && [ "$d" -ge "$MIN_DAYS" ]; then ok "root trust anchor ${d}d left ($ROOT_PEM)"
  else bad "root trust anchor ${d:-?}d left (< ${MIN_DAYS}d) — $ROOT_PEM — PLAN a root rotation"; fi
else
  echo "NOTE: root PEM $ROOT_PEM not found — skipping root check (run from repo root)."
fi

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "STEP-CA PKI ALERT: step-ca is unhealthy or a CA cert is approaching expiry. The fleet is"
  echo "SSH cert-only — a dead CA or an expired anchor = lockout (break-glass: PVE console + IPMI 10.10.200.21)."
fi
exit "$fail"
