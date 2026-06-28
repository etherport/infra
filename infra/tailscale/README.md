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

## How sync works (one-time setup)

The Tailscale admin console no longer offers a pull-from-GitHub
button (that older flow was deprecated). The current IaC pattern
is **push from CI to the Tailscale API**:

```
edit policy.hujson → git push main → GH Action POSTs to Tailscale API
  → policy live on the tailnet within ~30s
```

The GH Action lives at `.github/workflows/tailscale-policy.yml`.

**One-time setup**:

1. **Tailscale admin console → Personal Settings → Keys → Generate
   access token.** Scope: `tailnet policy file` (allows reading +
   writing the ACL only — no other tailnet powers). Save the value
   immediately — only shown once.
2. **GitHub repo → Settings → Secrets and variables → Actions → New
   repository secret** named `TAILSCALE_API_KEY` with the token
   value.
3. **First push** to `infra/tailscale/policy.hujson` triggers the
   workflow. Verify it succeeded (Actions tab).
4. **Lock the admin console editor** at
   <https://login.tailscale.com/admin/settings/policy-file> →
   "Prevent edits in the admin console". Optional but recommended
   — prevents drift from someone editing in the web UI directly.
5. **Set External reference** on the same page to
   `https://github.com/sparked-diamond/infra/blob/main/infra/tailscale/policy.hujson`.
   This is just a banner for human admins pointing at the source
   of truth.

Tailnet ID for reference: `TwxNUjPekr11CNTRL` (display name
`sparked-diamond.github`). The workflow uses `-` as the tailnet
shortcut so it doesn't need to know the specific ID.

## Editing workflow

1. Make the edit locally in `policy.hujson`.
2. (Optional) Validate locally with `hujsonfmt` if you have
   `tailscale/hujson` installed, or paste into the admin console's
   editor for a live syntax check + diff against the current policy.
3. PR or push to `main`. The `tailscale-policy.yml` workflow:
   - Runs `hujsonfmt` (or a fallback strict-JSON sanity check) on
     the file. Fails the PR if it doesn't parse.
   - On push to main: POSTs the file to
     `https://api.tailscale.com/api/v2/tailnet/-/acl`.
     200 = applied; 4xx = Tailscale rejected the policy (shown
     in workflow logs with the validation error).
4. Tailnet picks up the change within ~30s. No restart needed.

## Rotating / revoking the API key

If the `TAILSCALE_API_KEY` ever leaks or you want to rotate:

1. Admin console → Personal Settings → Keys.
2. Revoke the old token.
3. Generate a new one with the same scope (`acl:write`).
4. Update the `TAILSCALE_API_KEY` GitHub repo secret.
5. Push any commit to trigger the workflow with the new token.

Lifetime: the token doesn't expire unless you set it to. If you
want a TTL-bound token, set the expiry on creation; CI will start
failing when it expires, prompting rotation.

## If CI is down and you need to push

Manual API call from your laptop:

```bash
TS_API_KEY=$(op read 'op://Private/Tailscale API/credential')
curl -X POST \
  -H "Authorization: Bearer $TS_API_KEY" \
  -H "Content-Type: application/hujson" \
  --data-binary @infra/tailscale/policy.hujson \
  https://api.tailscale.com/api/v2/tailnet/-/acl
```

Same effect as the workflow. Avoids editing in the web UI which
would create drift.

## What's in the policy

See the inline comments in [`policy.hujson`](policy.hujson). High-level:

- **`tagOwners`**: 5 tags (`tag:k8s-operator`, `tag:k8s`,
  `tag:subnet-router`, `tag:homelab`, `tag:cluster-ingress`) and who can
  apply each. `tag:k8s` is the default tag the K8s operator applies to the
  per-Service proxy devices it creates (e.g. `cue-db`).
- **`grants`**: currently **allow-all** — every device can reach every
  other device on every port. Homelab posture; tighten when warranted.
- **`autoApprovers`**: subnet routes the tailnet auto-accepts when a
  `tag:subnet-router` device advertises them
  (`10.10.192.0/19` wind VLANs + `10.10.100.0/22` AWS spokes).
- **`ssh`**: Tailscale SSH allowed only for `autogroup:member` →
  `autogroup:self`, gated by `action: check` (re-auth required at
  session start).
- **`nodeAttrs`**: grants the `mullvad` exit-node attribute to
  `autogroup:member` (the owner's devices can see + select Mullvad exit
  nodes; the add-on is billed per-device so it's granted in the ACL, not
  the admin console).

## Related code in this repo

- `infra/ansible/playbooks/tailscale.yml` — installs the Tailscale
  client on VMs.
- `platform/kubernetes/tailscale/` — the K8s operator + Connector
  CRDs that advertise the homelab subnets.
- `platform/kubernetes/auto-remediation/approval-ingress.yaml` —
  uses the `tailscale` IngressClass; carries
  `tailscale.com/tags: tag:cluster-ingress` (swapped under L12).
