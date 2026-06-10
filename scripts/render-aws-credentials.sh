#!/usr/bin/env bash
# Render ~/.aws/credentials [homelab] profile from the SOPS-encrypted secret.
#
# WHY: terraform's S3 remote-state backend (terraform.wind.etherport.net) uses
# `profile = "homelab"`, which reads ~/.aws/credentials. On a headless ops host
# (the Mac mini RC box, the dev box, CI) there is no 1Password — but the AWS
# IAM keys are baked into homelab-ops.sops.yaml and decrypt with the on-disk age
# key alone. This script extracts them and writes the profile. No `op`, no unlock.
#
# Prereqs: sops + age key on disk (SOPS_AGE_KEY_FILE or default path), aws CLI.
# Run after `scripts/sync-secrets.py` has populated the AWS keys in the SOPS file.
#
#   scripts/render-aws-credentials.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_FILE="$ROOT/infra/ansible/playbooks/secrets/homelab-ops.sops.yaml"
PROFILE="homelab"
REGION="us-west-2"   # matches the terraform S3 backend region

command -v sops >/dev/null || { echo "ERROR: sops not on PATH" >&2; exit 1; }
command -v aws  >/dev/null || { echo "ERROR: aws CLI not on PATH" >&2; exit 1; }

plain="$(sops -d "$SOPS_FILE")"
akid="$(printf '%s' "$plain" | sed -n 's/^aws_access_key_id: *//p'     | tr -d '"')"
secret="$(printf '%s' "$plain" | sed -n 's/^aws_secret_access_key: *//p' | tr -d '"')"

if [ -z "$akid" ] || [ -z "$secret" ]; then
  echo "ERROR: aws_access_key_id / aws_secret_access_key not found in $SOPS_FILE" >&2
  echo "       Run scripts/sync-secrets.py (with 1Password unlocked) first." >&2
  exit 1
fi

# `aws configure set` edits the INI in place — won't clobber other profiles.
aws configure set aws_access_key_id     "$akid"   --profile "$PROFILE"
aws configure set aws_secret_access_key "$secret" --profile "$PROFILE"
aws configure set region                "$REGION" --profile "$PROFILE"
chmod 600 "$HOME/.aws/credentials" 2>/dev/null || true

echo "wrote ~/.aws/credentials [$PROFILE] (region $REGION) from SOPS — no 1Password needed"
echo "verify:  AWS_PROFILE=$PROFILE aws sts get-caller-identity"
