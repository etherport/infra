# AI Advisor — Phase 2 Enable Runbook

Phase 2 = **email diagnoses include Approve/Reject buttons**. Click
Approve → the controller's K8s ServiceAccount executes the proposed
action (restart_pods or scale_deployment_temp). Click Reject → marked
false-positive, cooldown applied. Phase 1 (advisory-only) keeps
working alongside; if Phase 2 is off, you get text-only emails as
before.

Architecture detail in
`docs/planning/ai-advisor-phases-2-3-scope.md`. Spec:
`docs/planning/ai-alert-remediation-2026-05-23.md`.

## Prerequisites

Phase 1 must already be running (`AI_ADVISOR_ENABLED=true`). If
it's off, finish `docs/runbooks/ai-advisor-phase1-enable.md` first.

What's already shipped in the cluster from the Phase 2 commit:

- HMAC secret: `ai-advisor-approval-hmac` (populated with a random
  32-byte key; rotate via `sops <file>` if it ever leaks).
- Controller code: `/approve` GET handler that verifies HMAC + executes.
- Tailscale Ingress: `auto-remediation/remediation-approve` → service.
- Multipart email path: text-only fallback + HTML with buttons.

## Steps to turn on

### 1. Wait for the Tailscale operator to provision the Ingress hostname

After the first commit lands and Flux applies, the Tailscale operator
in `tailscale` namespace creates a magicdns hostname for the new
ingress.

```bash
kubectl get ingress -n auto-remediation
# Wait for ADDRESS column to populate

kubectl logs -n tailscale deploy/operator | grep -i remediation | tail -10
# Look for: "exposed via ingress" + the hostname assigned
```

Once the operator logs an assigned hostname (form:
`remediation-approve.<tailnet>.ts.net`), copy it.

Alternative: look at the Tailscale admin console
(https://login.tailscale.com/admin/machines) for a new machine
named `remediation-approve` and note its MagicDNS name.

### 2. Set APPROVAL_BASE_URL on the deployment

Edit `platform/kubernetes/auto-remediation/deployment.yaml`:

```yaml
- name: APPROVAL_BASE_URL
  value: "https://remediation-approve.<your-tailnet>.ts.net"
```

…where `<your-tailnet>` is your specific tailnet (e.g.
`tail-scale.ts.net` or `<orgname>.ts.net`).

### 3. Flip the toggle

In the same file:

```yaml
- name: AI_PHASE2_ENABLED
  value: "true"
```

### 4. Commit + push

```bash
git add platform/kubernetes/auto-remediation/deployment.yaml
git commit -m "M41 P2: enable approve-via-email (APPROVAL_BASE_URL configured)"
git push
kubectl annotate -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

Controller pod will roll. Startup banner should say
`phase2=on`:

```bash
kubectl logs -n auto-remediation deploy/remediation-controller | head -5
# Expected:
#   Auto-remediation webhook server listening on port 8080
#   (ai_advisor=on, phase2=on, daily_cap=$0.5, model=claude-sonnet-4-6)
```

### 5. Smoke test

Fire a synthetic alert whose proposed action is NOT `noop`. The
easiest way: use the `AdvisorSmokeTest` alertname with an actionable
context. But since `AdvisorSmokeTest` always returns `noop`, you'll
have to wait for a real alert.

To force-test the Approve flow without waiting:

```bash
# 1. Look up the most recent successful advisor diagnosis that had
# a non-noop proposal:
kubectl logs -n auto-remediation deploy/remediation-controller \
  | grep ai_advisor | grep -v noop | tail -3

# 2. Or: send a synthetic alert that matches a real not-yet-rule'd
# alertname (one that genuinely has a pod to restart):
kubectl run test-p2 -n auto-remediation --rm -i --restart=Never \
  --image=curlimages/curl:latest --quiet --command -- \
  curl -sS -X POST http://remediation-webhook:8080 \
  -H 'Content-Type: application/json' \
  -d '{ ... synthetic alert that targets a real pod ... }'
```

Then check email for the Approve/Reject buttons.

## What happens when you click Approve

```
GET https://remediation-approve.<tailnet>.ts.net/approve?id=<id>&token=<sig>&decision=approve
↓
controller verifies HMAC(id) == sig (constant-time compare)
↓
controller pulls stored proposal from _pending_proposals[id]
↓
controller dispatches via SAME executor used by static rule path
  (restart_pods or scale_deployment) — same K8s SA, same RBAC
↓
audit event: ai_advisor event=approved_executed
↓
browser shows: "Executed: restart_pods ns=X selector=Y"
```

## What happens when you click Reject

```
GET .../approve?id=<id>&token=<sig>&decision=reject
↓
audit event: ai_advisor event=rejected
↓
proposal dropped from pending map
↓
alertname enters cooldown (15min)
↓
browser shows: "Rejected. Marked as false positive."
```

## Public approval URL (alternative to Tailscale-only)

Phase 2 ships TWO ingresses:

| URL | Route via | Reach | Default? |
|---|---|---|---|
| `https://remediation-approve.tail48f596.ts.net/approve?...` | Tailscale | Tailnet-only devices | ✅ in `APPROVAL_BASE_URL` |
| `https://approve.wind.etherport.net/approve?...` | Traefik public ingress + wildcard cert | Any device, any network | available, not default |

Both hit the same controller `/approve` endpoint. The HMAC-signed
`token` parameter is the auth — anyone with a valid token can
approve; the link is delivered only via DKIM-signed email to one
inbox. Token cannot be forged without the in-cluster
`APPROVAL_HMAC_KEY` secret.

**To switch the default to public** (so you can approve without
Tailscale, e.g. from a phone that isn't on TS):

```yaml
# In platform/kubernetes/auto-remediation/deployment.yaml:
- name: APPROVAL_BASE_URL
  value: "https://approve.wind.etherport.net"
```

Commit + push, Flux reconciles, the controller emails new links
pointing at the public URL. The Tailscale URL keeps working (the
ingress stays up) — only the email links change.

**Risk delta:** moving from TS-only to public expands the attack
surface from "must compromise the inbox AND have TS access" to
"must compromise the inbox alone". Given (a) tokens expire in
24h, (b) action allowlist is restart_pods + scale_deployment_temp,
(c) namespace denylist excludes kube-system / cnpg-system / etc.,
(d) cooldown prevents repeat-fire, the worst case is a single
pod restart in a non-system namespace. Acceptable for homelab.

## Tuning knobs

| Env | Default | Purpose |
|---|---|---|
| `AI_PHASE2_ENABLED` | `false` | Master switch for the approve-via-email path |
| `APPROVAL_BASE_URL` | (empty) | The Tailscale hostname for the controller; empty disables Phase 2 even if `AI_PHASE2_ENABLED=true` |
| `APPROVAL_TTL_HOURS` | `24` | How long approve links stay valid |
| `APPROVAL_HMAC_KEY` | (secret) | Signing key — rotate by re-editing the SOPS secret |

## Security model

- **HMAC tokens** are bound to specific `proposal_id` values. A
  spoofed email with a forged URL can't be approved unless the
  attacker holds the HMAC key (which lives only in the SOPS-encrypted
  secret + controller pod env).
- **Tailscale-only access**: the ingress is only reachable from your
  Tailscale-joined devices. An attacker on the public internet can't
  reach `/approve` at all.
- **Cooldown** prevents repeat approves from flap-spamming the cluster.
- **Single-replica controller**: if the pod restarts between email
  sent and approve clicked, the in-memory pending map is empty and
  the user sees "Expired/restarted". Acceptable for Phase 2; move to
  ConfigMap-backed state if it bites.

## Rollback

Set `AI_PHASE2_ENABLED=false` in deployment.yaml, commit, push.
Controller falls back to Phase-1-style emails (no Approve buttons,
text-only). Existing pending proposals expire by TTL.

Full revert: `git revert` the Phase 2 commit. RBAC unchanged from
Phase 1; no cleanup needed.

## Phase 3 — when to graduate

After Phase 2 has run for ~2 weeks with the operator approving
diagnoses regularly, the audit log will show which alerts the AI
gets right consistently. Add `ai_remediation: auto` label to those
specific alerts in `comprehensive-alerts.yaml` to opt them into
autonomous execution. See
`docs/planning/ai-advisor-phases-2-3-scope.md` for Phase 3 trigger
conditions.
