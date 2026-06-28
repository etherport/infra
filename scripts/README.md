# scripts

Helper scripts for the homelab. Index of the notable ones:

| Script | Purpose |
|--------|---------|
| `network/safety-check.sh` | Pre-change network safety check (run before touching network/firewall config) |
| `render-aws-credentials.sh` | Writes the `~/.aws` `[homelab]` profile from SOPS (S3 TF backend auth) |
| `tf-proxmox.sh` | Runs Terraform against a Proxmox stack, injecting the PVE token: `tf-proxmox.sh <stack> <args>` |
| `push-claude-creds.sh` | Pushes Claude Code credentials (devbox session bootstrap) |
| `setup-terminal.sh` | Terminal/shell environment setup |
| `sync-secrets.py` | Sync/reconcile SOPS-encrypted secrets |
| `check-service-status-inventory.py` | Inventory check of service status |
| `cilium/audit-report.py` | Build a Cilium NetworkPolicy audit report from Hubble/audit data |
| `unifi/dump-state.sh` | Dump UniFi controller state (read-only audit; used by the Talk runbook) |
| `pre-commit/check-sops-encryption.sh` | Pre-commit gate blocking plaintext secrets |
| `dotfiles/ssh-config` | SSH config dotfile |

See **CLAUDE.md** for how these fit into the operating model (e.g.
`render-aws-credentials.sh` + `tf-proxmox.sh` are for rare local-debug TF on the
devbox only — Terraform normally runs CI-only via OIDC / the self-hosted runner
(M82) and the devbox holds no standing creds, so these re-render creds on demand
as throwaways — §4).
