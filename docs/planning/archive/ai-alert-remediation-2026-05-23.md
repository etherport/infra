# AI-Augmented Alert Remediation — design spec

Status: PROPOSED (2026-05-23). Owner: graham.
Implements: extension to existing M8 auto-remediation webhook (`platform/kubernetes/auto-remediation/`).
Tracker entry: M41 (to be added).

## Goal

Take the existing rule-based auto-remediation controller and add a
second path that uses Claude (Anthropic API) to diagnose and propose
remediation for alerts that don't match any built-in rule, plus
enrich alerts that do.

The current controller is binary: if `alertname` is in the YAML rules,
take the canned action; otherwise drop the alert. That misses the long
tail of one-off problems (CNPG quorum loss in a new way, an OOM that
isn't a known offender, a Loki ingestion stall) where a human-style
read of recent logs + cluster state would diagnose the cause in
seconds but no static rule was ever written.

## Non-goals

- **No autonomous destructive actions.** No `delete pvc`, no
  `terraform apply`, no SSH-based execution. The LLM never sees a
  shell.
- **No replacing the existing rule path.** The static `rules.yaml`
  remains authoritative and fires first; the LLM path runs only when
  no rule matches, OR in parallel as enrichment.
- **No vendor lock-in.** Provider-agnostic interface so the LLM call
  can swap to a different model behind a flag.
- **No expanding RBAC beyond the controller's current scope.** It
  already has the K8s permissions it needs (read pods + restart +
  scale); we add Loki query access and Anthropic egress and that's it.

## Architecture

```
Alertmanager
     │  webhook POST (firing alert)
     ▼
┌──────────────────────────────────────────────────────────────────┐
│  auto-remediation controller (Python, existing pod)              │
│                                                                  │
│   ┌─ rule match?  ──yes──► canned action (existing) ────► done   │
│   │                                                              │
│   └─── no ──► AI advisor path (NEW)                              │
│                  │                                               │
│                  ├─► fetch context:                              │
│                  │     • kubectl get/describe (target pod/dep)   │
│                  │     • kubectl logs --tail=200                 │
│                  │     • Loki LogQL: ±5m around alert            │
│                  │     • Alert annotations + labels              │
│                  │                                               │
│                  ├─► POST /v1/messages (Anthropic API)           │
│                  │   model=claude-sonnet-4-6                     │
│                  │   system=remediation-advisor.md prompt        │
│                  │   user=structured JSON: alert + context       │
│                  │   response_format: {                          │
│                  │     diagnosis: str,                           │
│                  │     confidence: 0-1,                          │
│                  │     proposed_action: {                        │
│                  │       type: noop|restart_pods|scale|...       │
│                  │       params: {...},                          │
│                  │       reasoning: str                          │
│                  │     },                                        │
│                  │     human_summary: str                        │
│                  │   }                                           │
│                  │                                               │
│                  └─► route based on mode + confidence:           │
│                       • advisory: post diagnosis to Slack/email  │
│                       • propose:  Slack with [approve] [reject]  │
│                       • auto:     execute if action in allowlist │
│                                   + confidence >= threshold      │
└──────────────────────────────────────────────────────────────────┘
```

## Safety model

Three operating modes, settable per-alert via Alertmanager label
`ai_remediation: advisory|propose|auto`. Default `advisory`.

| Mode | What it does | Failure mode |
|---|---|---|
| `advisory` | LLM diagnoses; controller posts to Slack/email; no action | Useless suggestion — ignored. Worst case: noise. |
| `propose` | LLM diagnoses + proposes action; posts to Slack with **Approve / Reject** buttons (Slack interactive callback); on approve, executes via existing controller paths | Bad proposal — user catches in review. Latency added. |
| `auto` | LLM diagnoses + executes IF the proposed action is in `auto_allowlist` AND `confidence >= 0.85` AND no other action in the last 15min for the same alertname (cooldown) | Wrong action taken. Mitigation: allowlist is a tight subset of the rule-based actions (`restart_pods`, `scale_deployment_temp`), nothing destructive. |

**Hard guardrails enforced in code, not prompt:**
- Action types restricted to existing controller methods. The LLM
  cannot invent new action types; the controller's executor parses
  `proposed_action.type` against a fixed enum and rejects everything
  else, regardless of what the LLM "says."
- Namespace allowlist (default: every namespace except `kube-system`,
  `flux-system`, `cert-manager`, `cnpg-system`, `rook-ceph` —
  configurable).
- Cooldown table identical to rule path (per alertname, 15min).
- Audit trail: every LLM call + proposed action + outcome appended to
  a ConfigMap (or PV) for review.
- Cost cap: per-day token budget; controller refuses to call API
  beyond it and falls back to "post raw alert to Slack."

## Data fetched as context for each alert

Built by the controller before the Claude call. Bounded by token
budget (target <8K input tokens / call).

1. **Alert payload** — full Alertmanager JSON.
2. **Target resource** — `kubectl get` + `describe` for whatever the
   alert labels indicate (pod, deployment, statefulset, node).
3. **Pod logs** — `kubectl logs --tail=200 --since=10m` for the
   referenced pod(s). All containers.
4. **Loki window** — LogQL query for `{namespace="X", pod="Y"}` for
   the 5 min before and 1 min after `startsAt`, capped at 300 lines.
   If the alert is syslog-based (`{job="syslog"}`), query the
   matching `host` + `app` labels.
5. **Related K8s events** — `kubectl get events --namespace=X
   --field-selector involvedObject.name=Y --sort-by=lastTimestamp`.
6. **Recent prior alerts** — last 24h of alerts for the same `alertname`
   from Prometheus AlertHistory (so the LLM knows if this is flapping).

## Prompt design

System prompt lives in repo at
`platform/kubernetes/auto-remediation/prompts/advisor.md`. Versioned
in git. Key points it must convey:

- The LLM is an advisor on a homelab K8s cluster. Not enterprise scale.
- The cluster's quirks: Ceph RBD storage, MetalLB L2 (BGP planned),
  CNPG, GitOps via Flux. Hardware: PVE host (ASRock B650D4U) + GPU
  worker. Network: VLAN-segmented, mgmt VLAN 200, services 201.
- Available action types and what each one does. Anything outside this
  list is rejected by the executor — don't waste tokens proposing it.
- Output a JSON object matching a strict schema (validated server-side).
- Confidence semantics: 0.95+ = "I have seen this exact failure
  signature in the context"; 0.7-0.95 = "very likely this cause";
  <0.7 = "guess — recommend human review."
- If the situation is unfamiliar or context is insufficient, return
  `proposed_action: {type: "noop"}` with the diagnosis only.

User prompt is structured JSON, not natural language, so the LLM
can't get distracted by formatting. Example:

```json
{
  "alert": { "alertname": "...", "labels": {...}, "annotations": {...}, "startsAt": "..." },
  "target": { "kind": "Pod", "namespace": "...", "name": "...", "spec": {...}, "status": {...} },
  "logs": [{ "container": "...", "lines": [...] }],
  "loki": [...],
  "events": [...],
  "history": { "last_24h_fires": 3, "last_resolution": "auto-restart" }
}
```

## Implementation milestones

**Phase 1 — advisory only (1 week).** Pure read-only. No action
execution from the AI path; just posts diagnosis to Slack/email
when no rule matches. Validates prompt quality + cost.
- Extend `controller.py` with `ai_advisor.py` module.
- Add Anthropic API key as SOPS-encrypted Secret.
- Add Slack webhook (or extend existing email path) as output sink.
- Token-budget guard + per-day cost cap.
- Audit ConfigMap.

**Phase 2 — propose mode (1 week).** Add Slack interactive callback
or Email with approval link. Approval flips a flag; the controller
re-fetches the proposal from its audit log and executes.

**Phase 3 — auto mode (gated).** Only enabled per-alert via explicit
Alertmanager label `ai_remediation: auto`. Default stays `advisory`.
Allowlist is `restart_pods` + `scale_deployment_temp` only.
Confidence threshold 0.85+. Hard cooldown 15min. Mandatory audit log
entry with reasoning before execution.

**Phase 4 (optional) — feedback loop.** When the user marks a
canned-action remediation as "wrong" in Slack/email, log that as
training signal in the audit table. Periodically pull the audit log
and review for missed rule opportunities (cases the AI handled well
that should become static rules; cases it handled poorly that need
human attention upgrades).

## Cost estimate

Assuming:
- Alert volume: ~30 firing alerts/day on this cluster (today)
- Of those, ~5/day fall through to the AI path
- Average context: ~6K input + ~1K output tokens
- Sonnet 4.6 pricing: $3/M input + $15/M output

Per day: 5 × (6K × $3/M + 1K × $15/M) = 5 × ($0.018 + $0.015) = **~$0.17/day**
Per month: **~$5**. Well within homelab budget.

Hard cap configurable; default $0.50/day. At cap the controller falls
back to "post raw alert to Slack with no AI commentary."

## Rollback

The AI advisor module is a single Python file with no shared state
outside the audit ConfigMap. Disabling = set env var
`AI_ADVISOR_ENABLED=false` on the controller deployment, controller
auto-falls-back to the existing rule-only path. No data migration
required. The audit ConfigMap can stay or be deleted; nothing depends
on it.

## Decision points needing user input before Phase 1

1. **Slack vs email** as the diagnosis output sink. Both already exist
   for the cluster (Alertmanager uses email; do we have a Slack
   webhook?). Recommendation: extend the existing email digest first;
   Slack can come later if email turns out too slow for ops loop.
2. **Whose API key.** Use a dedicated Anthropic API key billed to the
   homelab account, stored as SOPS Secret. Not the user's personal
   Claude.ai key.
3. **First-batch allowlist for Phase 3.** Confirm: `restart_pods`,
   `scale_deployment_temp` — anything else?
4. **Cost cap.** Confirm $0.50/day default; raise/lower as desired.

## Open questions

- **Hallucination defense:** the LLM's JSON output is parsed strictly;
  any field outside the schema is dropped. Action type is enum-checked.
  But the *diagnosis text* sent to humans isn't validated — we trust
  the reader to sanity-check. Acceptable for advisory mode; revisit
  for propose/auto.
- **Loki query authorization:** the controller pod will need network
  policy to allow egress to `loki.monitoring.svc:3100`. Currently it
  only egresses to the K8s API. Add to the controller's NetworkPolicy.
- **Anthropic API outage:** controller falls back to advisory-as-Slack
  with "[AI advisor unavailable: $reason]" and the raw alert. The
  rule-based path is unaffected.
- **Prompt drift:** the system prompt is in-repo and code-reviewed.
  Each change requires a PR. Avoids the "someone tweaked the prompt
  and now it gives wrong answers" failure.
