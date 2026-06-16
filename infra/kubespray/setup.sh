#!/bin/bash
# Kubespray setup — run once after cloning, or when the kubespray submodule version
# changes. Creates the venv kubespray.sh expects ($HOME/.kubespray-venv by default).
# kubespray v2.30 needs ansible 10.7.0 (core 2.17) — DON'T use the system ansible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"                 # git submodule (playbooks)
VENV="${KUBESPRAY_VENV:-$HOME/.kubespray-venv}"       # MUST match kubespray.sh

echo "=== Kubespray Setup ==="

# 1. Submodule
if [ ! -f "$KUBESPRAY_DIR/requirements.txt" ]; then
    echo "Initializing kubespray submodule..."
    git -C "$SCRIPT_DIR/../.." submodule update --init infra/kubespray/kubespray
fi

# 2. Virtualenv (outside the repo tree, shared with the wrapper)
if [ ! -x "$VENV/bin/ansible-playbook" ]; then
    echo "Creating venv at $VENV ..."
    python3 -m venv "$VENV"
fi
echo "Installing Python deps (ansible 10.7.0 / core 2.17) ..."
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -r "$KUBESPRAY_DIR/requirements.txt"

echo ""
echo "=== Setup Complete ==="
echo "Run kubespray via the wrapper (it uses inventory/inventory.ini + auto-runs"
echo "pre-flight.yml after cluster.yml to keep /opt/cni/bin root-owned for Cilium):"
echo "  $SCRIPT_DIR/kubespray.sh cluster.yml"
echo "  $SCRIPT_DIR/kubespray.sh cluster.yml --tags=cilium,download"
echo "See docs/runbooks/cilium-cni-dir-owner.md for the full run path + gotchas."
