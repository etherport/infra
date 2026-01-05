#!/bin/bash
# Kubespray wrapper script
# Usage: ./kubespray.sh <playbook> [additional ansible-playbook args]
#
# Examples:
#   ./kubespray.sh cluster.yml                    # Deploy cluster
#   ./kubespray.sh upgrade-cluster.yml            # Upgrade cluster
#   ./kubespray.sh scale.yml                      # Scale cluster
#   ./kubespray.sh cluster.yml --check            # Dry run
#   ./kubespray.sh cluster.yml --limit k8s-w1    # Target specific node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"
INVENTORY="$KUBESPRAY_DIR/inventory/wind/inventory.ini"

# Check if setup has been run
if [ ! -d "$KUBESPRAY_DIR/venv" ]; then
    echo "Error: Kubespray not set up. Run ./setup.sh first."
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <playbook> [ansible-playbook args]"
    echo ""
    echo "Common playbooks:"
    echo "  cluster.yml          - Deploy/update full cluster"
    echo "  upgrade-cluster.yml  - Upgrade Kubernetes version"
    echo "  scale.yml            - Add new nodes"
    echo "  remove-node.yml      - Remove a node"
    echo "  reset.yml            - Reset cluster (DESTRUCTIVE)"
    echo ""
    echo "Examples:"
    echo "  $0 cluster.yml"
    echo "  $0 upgrade-cluster.yml --limit k8s-w1"
    echo "  $0 cluster.yml --check --diff"
    exit 1
fi

PLAYBOOK=$1
shift

# Activate virtual environment
source "$KUBESPRAY_DIR/venv/bin/activate"

# Change to kubespray directory and run
cd "$KUBESPRAY_DIR"

echo "=== Running: ansible-playbook -i inventory/wind/inventory.ini $PLAYBOOK $@ ==="
echo ""

ansible-playbook -i inventory/wind/inventory.ini "$PLAYBOOK" --become "$@"
