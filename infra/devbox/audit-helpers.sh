#!/usr/bin/env bash
# Privileged read/dispatch helpers for the weekly doc/IaC drift audit (doc-drift-audit.sh).
#
# WHY THIS EXISTS: under the audit's scoped permissions (doc-drift-audit-permissions.json,
# `--permission-mode default`) the Claude Code bash matcher rejects `$(...)` command
# substitution and `VAR=x cmd` env-prefixes — exactly the shapes a hand-rolled
# `KEY=$(sops -d ... | grep ...); curl -H "X-API-Key: $KEY" ...` needs. Each subcommand here
# is ONE vetted command (allowed as `Bash(infra/devbox/audit-helpers.sh:*)`) that composes the
# secret + curl internally, so (a) the agent never needs substitution, and (b) the decrypted
# secret never lands in the audit log (only the helper's result does). Read-only + one dispatch.
set -euo pipefail
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
REPO="/home/ubuntu/code/infra"
OPS="$REPO/infra/ansible/playbooks/secrets/homelab-ops.sops.yaml"

sops_get() { sops -d "$OPS" | grep "^$1:" | sed -E "s/^$1: *//; s/^[\"']//; s/[\"']$//"; }

case "${1:-}" in
  udm)
    # audit-helpers.sh udm <rest-endpoint>   — read-only GET to the UDM network API.
    # e.g. `udm networkconf`, `udm firewall-policies`, `udm portforward`, `udm routing`.
    ep="${2:?usage: udm <rest-endpoint>}"
    key="$(sops_get udm_api_key)"
    curl -sk -H "X-API-Key: $key" \
      "https://10.10.200.1/proxy/network/api/s/default/rest/${ep}"
    ;;
  gh-get)
    # audit-helpers.sh gh-get <api-path>   — authenticated read-only GitHub API GET.
    # e.g. `gh-get issues?state=open&labels=tf-drift`. Path is relative to the repo.
    path="${2:?usage: gh-get <api-path>}"
    tok="$(sops_get github_dispatch_pat)"
    curl -fsS -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/sparked-diamond/infra/${path}"
    ;;
  dispatch-issue)
    # audit-helpers.sh dispatch-issue <clean|drift> [summary-file]
    # Dispatches post-doc-drift-issue.yml (its GITHUB_TOKEN posts/refreshes/closes the
    # doc-drift issue). clean -> close any open issue; drift -> post the base64'd summary.
    mode="${2:?usage: dispatch-issue <clean|drift> [summary-file]}"
    clean=false; [ "$mode" = clean ] && clean=true
    b64=""
    if [ "$clean" = false ]; then
      f="${3:?drift mode needs a summary-file}"
      [ -f "$f" ] || { echo "summary file not found: $f" >&2; exit 3; }
      b64="$(base64 -w0 "$f")"
    fi
    tok="$(sops_get github_dispatch_pat)"
    curl -fsS -X POST -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/sparked-diamond/infra/actions/workflows/post-doc-drift-issue.yml/dispatches" \
      -d "{\"ref\":\"main\",\"inputs\":{\"clean\":\"${clean}\",\"summary_b64\":\"${b64}\"}}"
    echo "dispatched post-doc-drift-issue (clean=${clean})"
    ;;
  *)
    echo "usage: audit-helpers.sh {udm <endpoint> | gh-get <api-path> | dispatch-issue <clean|drift> [summary-file]}" >&2
    exit 2
    ;;
esac
