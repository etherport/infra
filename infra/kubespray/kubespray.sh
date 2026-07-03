#!/bin/bash
# Kubespray wrapper — wind cluster. Runs from the DEVBOX (venv ~/.kubespray-venv).
# Usage: ./kubespray.sh <playbook> [extra ansible-playbook args]
#
#   ./kubespray.sh cluster.yml                           # deploy/update full cluster
#   ./kubespray.sh cluster.yml --tags=cilium,download    # reconfigure cilium
#   ./kubespray.sh upgrade-cluster.yml --limit k8s-w1
#   ./kubespray.sh cluster.yml --check --diff            # dry run
#
# SSH: the fleet is CERT-ONLY (M76) — the SSH_KEY default below is the RETIRED
# static key (every host now rejects it). On the devbox always override with the
# step-ca cert identity:
#   KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert ./kubespray.sh …
# (the step-ssh-renew loop keeps the cert fresh — 13h lifetime).
#
# Long runs (cluster.yml / upgrade-cluster.yml take 30–90+ min): run inside a
# DETACHED tmux session, not an agent-harness background task (those die with
# the session) — e.g.  tmux new -d -s kubespray '… ./kubespray.sh upgrade-cluster.yml …'
#
# CRITICAL: cluster.yml / upgrade-cluster.yml / scale.yml (incl. --tags=cilium) chown
# /opt/cni/bin to kube_owner (kube), which breaks Cilium's mount-cgroup on the next
# agent restart (Init:CrashLoopBackOff). This wrapper AUTO-RUNS pre-flight.yml
# afterward to restore root ownership. See docs/runbooks/cilium-cni-dir-owner.md.
# Always run kubespray via THIS wrapper — raw ansible-playbook bypasses the post-fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"                 # git submodule (playbooks live here)
INVENTORY="$SCRIPT_DIR/inventory/inventory.ini"       # wind inventory (outside the submodule)
PREFLIGHT="$SCRIPT_DIR/inventory/pre-flight.yml"
VENV="${KUBESPRAY_VENV:-$HOME/.kubespray-venv}"       # ansible 11.13 / core 2.18 (kubespray v2.31)
SSH_USER="${KUBESPRAY_SSH_USER:-ubuntu}"
SSH_KEY="${KUBESPRAY_SSH_KEY:-$HOME/.ssh/id_ed25519_homelab}"

if [ ! -x "$VENV/bin/ansible-playbook" ]; then
    echo "Error: kubespray venv missing at $VENV. Create it with:"
    echo "  python3 -m venv $VENV && $VENV/bin/pip install -r $KUBESPRAY_DIR/requirements.txt"
    exit 1
fi
if [ ! -f "$KUBESPRAY_DIR/cluster.yml" ]; then
    echo "Error: kubespray submodule not checked out. Run:"
    echo "  git submodule update --init $KUBESPRAY_DIR"
    exit 1
fi
if [ $# -lt 1 ]; then
    echo "Usage: $0 <playbook> [ansible-playbook args]"
    echo "  cluster.yml | upgrade-cluster.yml | scale.yml | remove-node.yml | reset.yml(DESTRUCTIVE)"
    exit 1
fi

PLAYBOOK="$1"; shift
RUN=("$VENV/bin/ansible-playbook" -i "$INVENTORY" -b -u "$SSH_USER" --private-key "$SSH_KEY")

cd "$KUBESPRAY_DIR"
echo "=== ${RUN[*]} $PLAYBOOK $* ==="
echo ""
"${RUN[@]}" "$PLAYBOOK" "$@"

# Post-fix: any cluster-mutating play re-chowns /opt/cni/bin to kube_owner → restore root,
# or Cilium agents Init:CrashLoopBackOff on their next restart.
case "$PLAYBOOK" in
    cluster.yml|upgrade-cluster.yml|scale.yml)
        echo ""
        echo "=== Post-run: restoring /opt/cni/bin ownership (Cilium fix) via pre-flight.yml ==="
        "${RUN[@]}" "$PREFLIGHT"
        ;;
esac
