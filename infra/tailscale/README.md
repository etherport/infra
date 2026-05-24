# Tailscale tailnet policy (`infra/tailscale/`)

This directory holds the source-of-truth tailnet ACL / policy file.
The Tailscale admin console can pull this file directly from GitHub
on every push, eliminating the manual "edit in web UI" workflow that
drifts over time.

## Files

| File | Purpose |
|---|---|
| [`policy.hujson`](policy.hujson) | The actual policy. HuJSON format (JSON + comments + trailing commas). |
| [`README.md`](README.md) | You are here. |

## How GitHub-sync works (one-time setup)

The Tailscale admin console at <https://login.tailscale.com/admin/settings/general>
has an **"Sync from GitHub"** option under *General Settings → Tailnet
policy file*. Configure once:

1. **Connect the Tailscale GitHub App** to the `sparked-diamond/infra`
   repository. App permissions needed: read on repository contents +
   pull-request write (for posting validation comments).
2. **Set the path** to `infra/tailscale/policy.hujson`.
3. **Set the branch** to `main`.
4. **Enable sync.** Tailscale will validate the file on every push
   to main and apply the new policy if it parses cleanly.

Once enabled, this file is the canonical policy. Editing in the web
UI still works but **only as a sandbox** — the next git push
overwrites whatever was edited live. To make a real change: edit
this file, PR, merge.

Doc: <https://tailscale.com/kb/1407/sync-acls-from-github>

## Editing workflow

1. Make the edit locally. Validate the file parses as HuJSON by
   pasting it into the **"Edit file"** sandbox in the Tailscale admin
   console — it shows syntax errors + a live diff against the
   currently-deployed policy. Don't `jq` this file (it'll reject the
   comments).
2. Commit + push (or PR if you'd like the Tailscale app to comment a
   diff on the PR before merge).
3. Within ~30s of the push landing on main, the tailnet picks up the
   new policy. The admin console shows the commit SHA of the
   currently-applied policy under *Settings → Tailnet policy file*.

## Rotating / revoking the sync

If you ever need to disconnect GitHub sync (e.g. compromised PAT,
broken sync, or just want to manage in web UI again):

1. Admin console → *General Settings → Tailnet policy file → Disconnect*.
2. Last-known policy stays applied. Future edits go via web UI.
3. To re-enable, repeat the connect flow above.

## What's in the policy

See the inline comments in [`policy.hujson`](policy.hujson). High-level:

- **`tagOwners`**: 4 tags (`tag:k8s-operator`, `tag:subnet-router`,
  `tag:homelab`, `tag:cluster-ingress`) and who can apply each.
- **`grants`**: currently **allow-all** — every device can reach every
  other device on every port. Homelab posture; tighten when warranted.
- **`autoApprovers`**: subnet routes the tailnet auto-accepts when a
  `tag:subnet-router` device advertises them
  (`10.10.192.0/19` wind VLANs + `10.10.100.0/22` AWS spokes).
- **`ssh`**: Tailscale SSH allowed only for `autogroup:member` →
  `autogroup:self`, gated by `action: check` (re-auth required at
  session start).

## Related code in this repo

- `infra/ansible/playbooks/tailscale.yml` — installs the Tailscale
  client on VMs.
- `platform/kubernetes/tailscale/` — the K8s operator + Connector
  CRDs that advertise the homelab subnets.
- `platform/kubernetes/auto-remediation/approval-ingress.yaml` —
  uses the `tailscale` IngressClass; carries
  `tailscale.com/tags: tag:subnet-router` until L12 swaps it to
  `tag:cluster-ingress`.
