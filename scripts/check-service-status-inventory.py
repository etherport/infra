#!/usr/bin/env python3
"""
Drift check between the service-status inventory (services.py) and the
live cluster.

Reports three categories:

  STALE — in the inventory but NOT in the cluster. These are stale
    entries; the dashboard/email will show them as "UNKNOWN" or "DOWN"
    forever. Remove them from services.py.

  UNTRACKED — in the cluster but NOT in the inventory, filtered to
    workloads in tenant namespaces. May or may not warrant inclusion —
    needs human judgment. Listed so additions don't get forgotten.

  OK — both inventoried and present (or genuinely external).

Exit codes:
  0  no STALE entries
  1  one or more STALE entries (use in CI gates)
  2  could not reach cluster

Usage:
    python3 scripts/check-service-status-inventory.py
    python3 scripts/check-service-status-inventory.py --untracked   # also list untracked
"""

import json
import os
import subprocess
import sys
from collections import defaultdict

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "platform", "kubernetes",
                                "monitoring", "service-status-report"))
from services import SERVICES  # noqa: E402


# Namespaces to scan for UNTRACKED workloads. We deliberately exclude
# kube-system, gpu-operator-system, etc. — they have a lot of churn that
# isn't service-status signal.
TENANT_NAMESPACES = {
    "monitoring", "traefik", "cert-manager", "flux-system",
    "metallb-system", "wireguard", "cnpg-system",
    "dns", "velero", "backups",
    "home-automation", "plex", "ollama",
    "default",          # for ceph-csi
    "tailscale",
    "auto-remediation",
}


def kget(kind):
    """Return list of (namespace, name) for the given workload kind."""
    try:
        out = subprocess.run(
            ["kubectl", "get", kind, "-A", "-o", "json"],
            capture_output=True, text=True, timeout=15, check=True,
        ).stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"ERROR: kubectl get {kind} failed: {e}", file=sys.stderr)
        sys.exit(2)
    data = json.loads(out)
    return [(item["metadata"]["namespace"], item["metadata"]["name"])
            for item in data.get("items", [])]


def main():
    show_untracked = "--untracked" in sys.argv[1:]

    cluster_deploys = set(kget("deployment"))
    cluster_sts     = set(kget("statefulset"))
    cluster_ds      = set(kget("daemonset"))

    cluster_by_kind = {
        "deployment":  cluster_deploys,
        "statefulset": cluster_sts,
        "daemonset":   cluster_ds,
    }

    inv_by_kind = defaultdict(set)
    for _, _, kind, ns, target in SERVICES:
        if kind == "external":
            continue  # external probes aren't K8s workloads
        inv_by_kind[kind].add((ns, target))

    stale_lines = []
    for kind, inv_set in inv_by_kind.items():
        for ns, target in sorted(inv_set):
            if (ns, target) not in cluster_by_kind[kind]:
                stale_lines.append(f"  {kind:11s} {ns}/{target}")

    untracked_lines = []
    if show_untracked:
        for kind in ("deployment", "statefulset", "daemonset"):
            for ns, name in sorted(cluster_by_kind[kind]):
                if ns not in TENANT_NAMESPACES:
                    continue
                if (ns, name) in inv_by_kind[kind]:
                    continue
                untracked_lines.append(f"  {kind:11s} {ns}/{name}")

    print(f"\nInventory size: {len(SERVICES)} services "
          f"(deployments={len(inv_by_kind['deployment'])}, "
          f"statefulsets={len(inv_by_kind['statefulset'])}, "
          f"daemonsets={len(inv_by_kind['daemonset'])}, "
          f"external={sum(1 for s in SERVICES if s[2]=='external')})")

    if stale_lines:
        print("\n❌ STALE — in services.py but not in cluster "
              "(dashboard/email will render as DOWN/UNKNOWN forever):\n")
        print("\n".join(stale_lines))
    else:
        print("\n✓ no stale inventory entries")

    if show_untracked:
        if untracked_lines:
            print(f"\n⚠  UNTRACKED — in cluster, not in services.py "
                  f"(in tenant ns only; {len(untracked_lines)} items):\n")
            print("\n".join(untracked_lines))
        else:
            print("\n✓ no untracked tenant workloads")

    sys.exit(1 if stale_lines else 0)


if __name__ == "__main__":
    main()
