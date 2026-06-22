#!/bin/bash
# Print the iCloud app-specific password to stdout, decrypted from the SOPS bundle (the mini
# holds the age key, so this works headlessly). Used by vdirsyncer's password.fetch (M80).
#
# One-time: add the secret to the bundle (interactively, the value never touches this repo):
#   sops infra/ansible/playbooks/secrets/homelab-ops.sops.yaml
#   # add a top-level line:  icloud_app_password: xxxx-xxxx-xxxx-xxxx   (from appleid.apple.com)
exec sops -d --extract '["icloud_app_password"]' \
  /Users/grahamsmith/code/infra/infra/ansible/playbooks/secrets/homelab-ops.sops.yaml
