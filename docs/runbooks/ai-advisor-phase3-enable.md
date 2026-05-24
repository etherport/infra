# AI Advisor — Phase 3 Enable (Autonomous execution, opt-in per alert)

Phase 3 = **the controller executes proposed actions without waiting
for human approval, but ONLY for specific alerts you opt-in.**

Phases 1 + 2 must already be running. If you haven't enabled
Phase 2, do that first
(`docs/runbooks/ai-advisor-phase2-enable.md`).

## What Phase 3 actually changes

Today (Phase 2): every advisor diagnosis with `action != noop`
generates an email with **Approve + Reject** buttons. You click;
controller acts.

With Phase 3 enabled AND a specific alert opted in:

```
alert fires → advisor diagnoses → if (label says auto) +
  (confidence >= 0.85) + (action in allowlist) + (namespace ok) →
  CONTROLLER EXECUTES IMMEDIATELY → emails you a receipt
```

If any condition fails, falls back to Phase 2 behavior (email with
buttons, wait for click).

## Hard guardrails (all enforced in code)

1. **Top-level kill switch.** `AI_PHASE3_ENABLED=false` (the default)
   means NOTHING auto-executes regardless of alert labels. One env
   flip reverts everything.
2. **Per-alert opt-in.** Only alerts whose PrometheusRule labels
   include `ai_remediation: "auto"` are candidates. Adding a new
   alert to Phase 3 requires editing its rule + committing — same
   review surface as any other config change.
3. **Action allowlist** unchanged from Phase 2: `restart_pods` +
   `scale_deployment_temp` only. `noop` produces no action by
   definition. Anything else is rejected by `_validate_response()`
   before reaching the execute branch.
4. **Namespace denylist** unchanged: `kube-system`, `flux-system`,
   `cnpg-system`, `cert-manager`, `rook-ceph`. Auto-execute proposals
   targeting any of these are downgraded to email.
5. **Confidence threshold.** Default 0.85 (`AI_PHASE3_CONFIDENCE_THRESHOLD`).
   Claude's confidence must be >= this OR we fall back to email.
6. **Cooldown.** Same 15-min cooldown as static rules + Phase 2.
   Prevents flap-spam auto-restarts.
7. **Audit log.** Every auto-execute emits
   `event=auto_executed` (success) or `event=auto_execute_failed`
   (failure) with full action params. Query in Loki:
   `{namespace="auto-remediation"} | json | tag="ai_advisor" | event=~"auto_.*"`
8. **Email receipt** sent for EVERY auto-execute. You see it after
   the fact; not asking permission but informing.

## To turn on (4 steps)

### 1. Flip the global toggle

Edit `platform/kubernetes/auto-remediation/deployment.yaml`:

```yaml
- name: AI_PHASE3_ENABLED
  value: "true"
```

Commit + push. Controller rolls. Startup banner now says
`phase3=on (opt-in via alert label)`.

**Nothing changes yet** — Phase 3 candidates are zero because no
alerts carry the label.

### 2. Pick the first alert to opt in

Recommendation: start with `NodeLocalDNSHighErrorRate`. It already
has a static remediation rule (restart NodeLocalDNS pods), so the
"correct" remediation is known + low-risk. Phase 3 just lets the
AI handle unusual variants the static rule doesn't catch.

```bash
grep -n "NodeLocalDNSHighErrorRate" platform/kubernetes/monitoring/*.yaml
```

### 3. Add the label to that alert

In whichever PrometheusRule file owns the alert (probably
`comprehensive-alerts.yaml`):

```yaml
- alert: NodeLocalDNSHighErrorRate
  expr: ...
  for: 5m
  labels:
    severity: warning
    auto_remediate: "true"     # existing — used by the rule-based path
    ai_remediation: "auto"     # NEW — Phase 3 opt-in
  annotations:
    ...
```

Commit + push. Flux reconciles Prometheus, the new label flows
through Alertmanager into the webhook payload.

### 4. Wait for the alert to fire (or force-fire it)

```bash
# Force a synthetic fire to test (no real outage required):
kubectl run test-p3 -n auto-remediation --rm -i --restart=Never \
  --image=curlimages/curl:latest --quiet --command -- \
  curl -sS -X POST http://remediation-webhook:8080 \
  -H 'Content-Type: application/json' \
  -d '{ "alerts": [{
    "status": "firing",
    "labels": {
      "alertname": "NodeLocalDNSHighErrorRate",
      "namespace": "kube-system",
      "ai_remediation": "auto",
      "severity": "warning"
    },
    "annotations": {
      "summary": "Synthetic test of Phase 3 autonomous execute",
      "description": "..."
    },
    "startsAt": "2026-05-24T18:00:00Z"
  }] }'
```

Then check the audit:

```bash
kubectl logs -n auto-remediation deploy/remediation-controller \
  | grep -E "auto_executed|auto_execute_failed" | tail -3
```

You should see one auto_executed line + receive a receipt email
with subject `[Etherport AI Advisor: AUTO-restart_pods] NodeLocalDNSHighErrorRate`.

Note: in the synthetic test above, the controller targets
`kube-system` which is in the denylist, so it'll downgrade to
email-only. That's the safety net working. Try with a non-denylist
namespace + a valid selector if you want a true auto-execute test.

## What happens if Phase 3 makes a bad call

You'll know within 1-2 minutes (the receipt email arrives). To
roll back:

```bash
# Immediate revert of the specific action:
kubectl rollout undo deploy/<deployment> -n <namespace>
# Or just delete and let it recreate.

# Remove the alert from Phase 3:
git revert <commit-that-added-ai_remediation:auto>
git push

# Or kill Phase 3 globally:
kubectl set env deploy/remediation-controller -n auto-remediation \
  AI_PHASE3_ENABLED=false
# This is immediate (no Flux wait). git revert the deployment.yaml
# change later to make it durable.
```

## Phased rollout recommendation

| Week | Alerts in Phase 3 |
|---|---|
| 1 | `NodeLocalDNSHighErrorRate` only |
| 2 | + `CoreDNSDown` |
| 3 | + `TechnitiumDNSDown`, `HomeAssistantDown` (well-understood restart targets) |
| 4+ | expand as comfort grows; never include CNPG / Ceph / kube-system alerts |

Audit log review after each addition: did the auto-execute match
what you would have done manually? If yes, expand. If no, remove
the label + investigate.

## Tuning knobs

| Env | Default | Purpose |
|---|---|---|
| `AI_PHASE3_ENABLED` | `false` | Top-level kill switch |
| `AI_PHASE3_CONFIDENCE_THRESHOLD` | `0.85` | Min confidence to auto-execute; lower = more autonomous, higher = more email-with-buttons fallback |
| `AI_NAMESPACE_DENYLIST` | hardcoded | Defense in depth; Phase 3 inherits Phase 2's denylist |
| `AI_ACTION_TYPES_ALLOWED` | `{noop, restart_pods, scale_deployment_temp}` | Phase 3 inherits; no expansion ever |

## Open follow-ups (Phase 4-ish)

- **Post-action verification**: after auto-restart, re-query the
  metric that triggered the alert. If it's still red 5min later,
  email + log "auto-execute didn't fix it". Currently you find out
  when the alert re-fires.
- **Feedback loop**: "this was wrong" button on receipt emails
  that adds the alertname to a do-not-auto list. Currently you
  revert via git.
- **Stats tracking**: track Phase 3 success/false-positive rate in
  Prometheus metrics + dashboard. Currently in the audit log only.

These are all easy adds when Phase 3 has 30 days of clean operation
and you want to extend further.
