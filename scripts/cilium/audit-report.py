#!/usr/bin/env python3
"""Cilium policy-audit-mode AUDIT-verdict report (H3 NetworkPolicy observation).

While Cilium runs in policy-audit-mode, traffic a policy WOULD deny is logged as an
AUDIT verdict but allowed through; allowed traffic is FORWARDED. So every AUDIT flow
to a namespace labelled `netpol.wind/enforced=true` is a **would-be-drop on
enforcement** — i.e. either a missing allowlist entry (add it) or genuinely-unwanted
lateral movement (leave it to be blocked). This script pulls cluster-wide AUDIT flows
from the hubble relay, dedupes them, and prints a table to drive allowlist refinement.

Usage:  python3 scripts/cilium/audit-report.py [--last N] [--since DURATION]
Needs:  kubectl context for the wind cluster (the mini). Reads the hubble relay via a
        `kubectl exec` into a cilium agent. See docs/runbooks/cilium-cni-dir-owner.md
        and platform/kubernetes/networkpolicies/README.md.
"""
import json
import subprocess
import sys
from collections import Counter

RELAY = "hubble-relay.kube-system.svc.cluster.local:80"
LAST = "4000"
for i, a in enumerate(sys.argv):
    if a == "--last" and i + 1 < len(sys.argv):
        LAST = sys.argv[i + 1]


def kubectl(args, **kw):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, **kw)


def main():
    ns = kubectl(["get", "ns", "-l", "netpol.wind/enforced=true",
                  "-o", "jsonpath={range .items[*]}{.metadata.name} {end}"]).stdout.split()
    if not ns:
        print("No namespaces labelled netpol.wind/enforced=true — nothing under observation.")
        return 0
    print(f"Observed (enforced-label) namespaces: {', '.join(ns)}")

    out = kubectl(["-n", "kube-system", "exec", "ds/cilium", "-c", "cilium-agent", "--",
                   "hubble", "observe", "--server", RELAY,
                   "--verdict", "AUDIT", "--last", LAST, "-o", "jsonpb"]).stdout

    flows = Counter()
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        f = rec.get("flow")
        if not f:                       # skip lost_events / node_status lines
            continue
        dst = f.get("destination", {})
        if dst.get("namespace") not in ns:
            continue
        src = f.get("source", {})
        sns = src.get("namespace") or "|".join(src.get("labels", [])[:1]) or "world"
        l4 = f.get("l4", {})
        proto = port = "-"
        for p in ("TCP", "UDP", "ICMPv4", "ICMPv6"):
            if p in l4:
                proto = p
                port = str(l4[p].get("destinationPort", "")) or "-"
                break
        flows[(dst.get("namespace", "?"), sns, proto, port)] += 1

    if not flows:
        print("\nNo AUDIT (would-be-denied) flows found — allowlists look complete so far.")
        print("(Re-check after the next CNPG backup/cron cycle before enforcing.)")
        return 0

    print(f"\n{'DST-NS':<14}{'SRC':<34}{'PROTO':<7}{'DPORT':<8}COUNT")
    print("-" * 70)
    for (dns, sns, proto, port), n in flows.most_common():
        print(f"{dns:<14}{sns:<34}{proto:<7}{port:<8}{n}")
    print("\nEach row = a flow that would be DROPPED on enforcement. Add legit ones to the"
          "\nrelevant per-tier CNP in platform/kubernetes/networkpolicies/; leave unwanted ones.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
