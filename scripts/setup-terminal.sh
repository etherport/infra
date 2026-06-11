#!/bin/bash
# Terminal Setup Script for Homelab Access
# Run this after cloning the homelab-infra repo on a fresh macOS install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Terminal Setup for Homelab Access ==="
echo ""

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    echo "Homebrew already installed"
fi

# Install CLI tools
echo ""
echo "Installing CLI tools..."
brew install git kubectl awscli jq python3 || true

# Install WireGuard (backup VPN)
brew install wireguard-tools || true

# Install apps
echo ""
echo "Installing applications..."
brew install --cask tailscale || true
brew install --cask 1password || true
brew install --cask nordvpn || true

# Setup dotfiles
echo ""
echo "Setting up dotfiles..."

# Backup existing configs
if [ -f ~/.zshrc ]; then
    cp ~/.zshrc ~/.zshrc.backup.$(date +%Y%m%d)
    echo "Backed up existing .zshrc"
fi

# Copy dotfiles
cp "$SCRIPT_DIR/dotfiles/.zshrc" ~/.zshrc
cp "$SCRIPT_DIR/dotfiles/.gitconfig" ~/.gitconfig

# Setup SSH
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp "$SCRIPT_DIR/dotfiles/ssh-config" ~/.ssh/config
chmod 600 ~/.ssh/config
echo "SSH config installed (uses 1Password agent)"

# Setup directories
mkdir -p ~/.kube
mkdir -p ~/.aws

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Manual steps required:"
echo ""
echo "1. OPEN 1Password and enable SSH Agent:"
echo "   Settings -> Developer -> SSH Agent -> Enable"
echo ""
echo "2. LOGIN to Tailscale:"
echo "   Open Tailscale app, authenticate via browser"
echo ""
echo "3. (Optional) LOGIN to NordVPN:"
echo "   Open NordVPN app, authenticate"
echo ""
echo "4. RESTORE kubeconfig from 1Password:"
echo "   Copy 'kubeconfig' secure note contents to ~/.kube/config"
echo "   chmod 600 ~/.kube/config"
echo ""
echo "5. RESTORE AWS credentials from 1Password:"
echo "   Copy 'AWS Credentials' secure note to ~/.aws/credentials"
echo "   Copy 'AWS Config' secure note to ~/.aws/config"
echo "   chmod 600 ~/.aws/credentials"
echo ""
echo "6. RELOAD shell:"
echo "   source ~/.zshrc"
echo ""
echo "Test connectivity:"
echo "  tailscale status"
echo "  kubectl get nodes"
echo "  aws sts get-caller-identity --profile homelab"
echo ""
echo "Tailscale aliases available:"
echo "  ts-split  - Split tunnel (homelab only)"
echo "  ts-aws    - Exit via AWS"
echo "  ts-home   - Exit via homelab"
echo "  ts-status - Show status"
