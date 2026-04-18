# Terminal Setup & Disaster Recovery

Guide for setting up a new macOS terminal with homelab access after a wipe/reinstall.

## Prerequisites

1. **1Password** - Handles SSH keys via agent
2. **Homebrew** - Package manager
3. **Git** - Version control

## Quick Setup (New Machine)

```bash
# 1. Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install essential tools
brew install git kubectl awscli wireguard-tools

# 3. Install apps
brew install --cask tailscale 1password nordvpn visual-studio-code

# 4. Clone homelab repo
mkdir -p ~/Projects && cd ~/Projects
git clone https://github.com/sparked-diamond/infra.git homelab-infra

# 5. Run setup script (see below)
~/Projects/homelab-infra/scripts/setup-terminal.sh
```

## Configuration Files to Restore

### From This Repository

| File | Destination | Notes |
|------|-------------|-------|
| `scripts/dotfiles/.zshrc` | `~/.zshrc` | Shell config, aliases |
| `scripts/dotfiles/.gitconfig` | `~/.gitconfig` | Git settings |
| `scripts/dotfiles/ssh-config` | `~/.ssh/config` | SSH config (1Password agent) |

### From 1Password

| Item | Usage |
|------|-------|
| SSH Keys | Automatically provided via 1Password SSH agent |
| AWS Credentials | Export to `~/.aws/credentials` (or use SSO) |
| Kubernetes Kubeconfig | Store as secure note, restore to `~/.kube/config` |

### Manual Configuration

| Config | How to Restore |
|--------|----------------|
| Tailscale | Login via browser, routes auto-configure |
| NordVPN | Login via app |
| Kubernetes | Regenerate kubeconfig from cluster |

## File Backup Strategy

### Stored in Git (This Repo)

```
homelab-infra/
├── scripts/
│   ├── setup-terminal.sh      # Automated setup
│   └── dotfiles/              # Shell configs, aliases
├── docs/
│   └── operations/
│       └── terminal-setup.md  # This file
└── infra/
    └── ansible/               # Infrastructure configs
```

### Stored in 1Password

- SSH private keys
- AWS credentials (access key ID + secret)
- Kubernetes kubeconfig (as secure note)
- VPN configs (WireGuard keys)

### Regeneratable (No Backup Needed)

- `~/.ssh/known_hosts` - Rebuilt on first connection
- Homebrew packages - Reinstall via `brew install`
- IDE settings - Sync via built-in account (VS Code, etc.)

## Setup Script

Create `scripts/setup-terminal.sh`:

```bash
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Terminal Setup for Homelab Access ==="

# Install Homebrew if needed
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install CLI tools
echo "Installing CLI tools..."
brew install git kubectl awscli wireguard-tools jq python3

# Install apps
echo "Installing applications..."
brew install --cask tailscale 1password nordvpn

# Copy dotfiles
echo "Setting up dotfiles..."
cp "$REPO_DIR/scripts/dotfiles/.zshrc" ~/.zshrc
cp "$REPO_DIR/scripts/dotfiles/.gitconfig" ~/.gitconfig
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp "$REPO_DIR/scripts/dotfiles/ssh-config" ~/.ssh/config
chmod 600 ~/.ssh/config

# Reload shell config
source ~/.zshrc

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Manual steps required:"
echo "1. Open 1Password and enable SSH Agent"
echo "2. Login to Tailscale (open app, authenticate via browser)"
echo "3. Login to NordVPN (open app, authenticate)"
echo "4. Restore kubeconfig from 1Password to ~/.kube/config"
echo "5. Restore AWS credentials from 1Password to ~/.aws/credentials"
echo ""
echo "Test connectivity:"
echo "  tailscale status"
echo "  kubectl get nodes"
echo "  aws sts get-caller-identity --profile homelab"
```

## Tailscale Aliases

Already added to `.zshrc`:

```bash
alias ts-split='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node='
alias ts-aws='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.87.10'
alias ts-home='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.63.43'
alias ts-status='/Applications/Tailscale.app/Contents/MacOS/Tailscale status'
```

## AWS Profile Configuration

`~/.aws/config`:
```ini
[profile homelab]
region = us-west-2

[profile claude-admin]
region = us-west-2
```

`~/.aws/credentials`:
```ini
[homelab]
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[claude-admin]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

## SSH Configuration

`~/.ssh/config`:
```
Host *
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

This routes all SSH authentication through 1Password's agent.

## Kubernetes Access

After Tailscale is connected:

```bash
# Test cluster access
kubectl get nodes

# If kubeconfig needs refresh, copy from a control plane node:
ssh ubuntu@10.10.201.50 "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
```

## Verification Checklist

After setup, verify:

- [ ] `tailscale status` shows peers
- [ ] `ssh ubuntu@10.10.100.10` connects to vpn-aws
- [ ] `kubectl get nodes` shows cluster nodes
- [ ] `aws sts get-caller-identity --profile homelab` shows account
- [ ] `ts-aws` switches to AWS exit node
- [ ] `ping 10.10.201.70` reaches homelab

## Troubleshooting

### Tailscale not connecting
1. Check NordVPN is disconnected (they conflict on macOS)
2. Re-authenticate: `tailscale logout && tailscale login`

### kubectl timeout
1. Ensure Tailscale is connected: `tailscale status`
2. Check route exists: `netstat -rn | grep 10.10`
3. Verify kubeconfig: `kubectl config view`

### AWS credentials expired
1. Regenerate in AWS IAM console
2. Update `~/.aws/credentials`

## Related Documentation

- [VPN Architecture - Tailscale](../architecture/vpn-tailscale.md)
- [VPN Architecture - WireGuard](../architecture/vpn-wireguard.md)
- [AWS Infrastructure](../architecture/aws-infrastructure.md)
