#!/usr/bin/env bash
# Run terraform in a proxmox/ stack with provider creds injected from SOPS.
#
# WHY: the bpg/proxmox provider authenticates with an API token
# (proxmox_token_id / proxmox_token_secret). CI passes these as TF_VAR_* from
# GitHub secrets; this is the local/headless equivalent — it decrypts
# infra/terraform/proxmox/secrets.sops.yaml with the on-disk age key and exports
# them into terraform's environment only. No 1Password, no creds on the shell.
# (The S3 backend creds come separately from ~/.aws/credentials [homelab];
#  see scripts/render-aws-credentials.sh.)
#
#   scripts/tf-proxmox.sh <stack> <terraform args...>
#   e.g.  scripts/tf-proxmox.sh k8s-vms plan
#         scripts/tf-proxmox.sh sdn init
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT/infra/terraform/proxmox/secrets.sops.yaml"
STACK="${1:?usage: tf-proxmox.sh <stack: k8s-vms|sdn|standalone-vms|firewall> <terraform args...>}"
shift
DIR="$ROOT/infra/terraform/proxmox/$STACK"
[ -d "$DIR" ] || { echo "ERROR: no such stack: $DIR" >&2; exit 1; }

command -v sops      >/dev/null || { echo "ERROR: sops not on PATH" >&2; exit 1; }
command -v terraform >/dev/null || { echo "ERROR: terraform not on PATH" >&2; exit 1; }

plain="$(sops -d "$SECRETS")"
export TF_VAR_proxmox_token_id="$(printf '%s' "$plain"     | sed -n 's/^proxmox_token_id: *//p'     | tr -d '"')"
export TF_VAR_proxmox_token_secret="$(printf '%s' "$plain" | sed -n 's/^proxmox_token_secret: *//p' | tr -d '"')"
if [ -z "$TF_VAR_proxmox_token_id" ] || [ -z "$TF_VAR_proxmox_token_secret" ]; then
  echo "ERROR: proxmox_token_id / proxmox_token_secret not found in $SECRETS" >&2
  exit 1
fi

exec terraform -chdir="$DIR" "$@"
