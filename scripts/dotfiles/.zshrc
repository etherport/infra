
# The next line updates PATH for the Google Cloud SDK.
if [ -f '/Applications/google-cloud-sdk/path.zsh.inc' ]; then . '/Applications/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/Applications/google-cloud-sdk/completion.zsh.inc' ]; then . '/Applications/google-cloud-sdk/completion.zsh.inc'; fi

# Tailscale exit node aliases
# ts-split: Split tunnel mode (only homelab traffic through Tailscale)
# ts-aws: Route ALL traffic through AWS (privacy + homelab access)
# ts-home: Route ALL traffic through homelab (use home IP)
alias ts-split='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node='
alias ts-aws='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.87.10'
alias ts-home='/Applications/Tailscale.app/Contents/MacOS/Tailscale set --exit-node=100.117.63.43'
alias ts-status='/Applications/Tailscale.app/Contents/MacOS/Tailscale status'
alias ts-ip='echo "Exit node: $(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"ExitNodeStatus\",{}).get(\"TailscaleIPs\",[\"-\"])[0] if d.get(\"ExitNodeStatus\") else \"none\")") | Public IP: $(curl -s ifconfig.me)"'
