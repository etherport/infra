#!/usr/bin/env bash
# check-sops-encryption.sh
#
# Pre-commit hook: ensure every *.sops.yaml file (excluding *.sops.yaml.template)
# is actually SOPS-encrypted (has a top-level `sops:` metadata block).
#
# Plaintext leaks of secrets are unrecoverable once pushed; this hook catches
# the common foot-gun of forgetting to run `sops -e` before staging.
#
# Args: list of files passed by pre-commit (already filtered by `files:` regex).
# Exit: 0 if all files are encrypted; 1 if any file lacks `sops:` metadata.

set -euo pipefail

failed=0
checked=0

for f in "$@"; do
    # Skip templates (they're plaintext examples on purpose).
    case "$f" in
        *.sops.yaml.template) continue ;;
    esac

    # Skip the SOPS rule config files themselves (.sops.yaml). These are the
    # creation-rules config, not encrypted payloads.
    base=$(basename "$f")
    if [ "$base" = ".sops.yaml" ]; then
        continue
    fi

    checked=$((checked + 1))

    # A SOPS-encrypted YAML file always has a top-level `sops:` key with
    # encryption metadata. Use yq if available for correctness; fall back to grep.
    if command -v yq >/dev/null 2>&1; then
        if ! yq -e '.sops' "$f" >/dev/null 2>&1; then
            echo "ERROR: $f is missing top-level 'sops:' metadata (not SOPS-encrypted)"
            failed=1
        fi
    else
        if ! grep -qE '^sops:' "$f"; then
            echo "ERROR: $f is missing top-level 'sops:' metadata (not SOPS-encrypted)"
            failed=1
        fi
    fi
done

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "One or more *.sops.yaml files are not SOPS-encrypted."
    echo "Encrypt with:  sops -e -i <file>"
    echo "Or rename to *.sops.yaml.template if it's a plaintext example."
    exit 1
fi

exit 0
