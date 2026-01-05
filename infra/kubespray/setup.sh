#!/bin/bash
# Kubespray setup script
# Run this once after cloning the repo or when updating kubespray

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"
INVENTORY_DIR="$SCRIPT_DIR/inventory"

echo "=== Kubespray Setup ==="

# Check if submodule is initialized
if [ ! -f "$KUBESPRAY_DIR/requirements.txt" ]; then
    echo "Initializing kubespray submodule..."
    git -C "$SCRIPT_DIR/../.." submodule update --init --recursive infra/kubespray/kubespray
fi

# Create virtual environment if it doesn't exist
if [ ! -d "$KUBESPRAY_DIR/venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "$KUBESPRAY_DIR/venv"
fi

# Activate and install requirements
echo "Installing Python dependencies..."
source "$KUBESPRAY_DIR/venv/bin/activate"
pip install -q --upgrade pip
pip install -q -r "$KUBESPRAY_DIR/requirements.txt"

# Create symlink to inventory
if [ ! -L "$KUBESPRAY_DIR/inventory/wind" ]; then
    echo "Linking inventory..."
    ln -sf "$INVENTORY_DIR" "$KUBESPRAY_DIR/inventory/wind"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To use kubespray:"
echo "  cd $KUBESPRAY_DIR"
echo "  source venv/bin/activate"
echo "  ansible-playbook -i inventory/wind/inventory.ini cluster.yml --become"
echo ""
echo "Or use the wrapper script:"
echo "  $SCRIPT_DIR/kubespray.sh cluster.yml"
