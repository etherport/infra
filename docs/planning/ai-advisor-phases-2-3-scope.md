# AI Advisor Phases 2 + 3 — Implementation Scope

Owner: graham. Status: PROPOSED (2026-05-24, after 24h of Phase 1
operation).

Phase 1 spec: `docs/planning/ai-alert-remediation-2026-05-23.md`.
This doc converts the Phase 2/3 sketches there into concrete
buildable units with code paths, dependencies, milestones, and
exit criteria.

## What Phase 1 taught us (24h data)

```
events_24h: 64 (28 cap_reached, 18 success, 18 start)
top_alertnames:
  44  InfoInhibitor                # all noop — STRUCTURAL NOISE
  18  NodeMemoryHighUtilization    # all noop — real signal but no fix
   2  AdvisorSmokeTest             # our manual tests
total_spend: $0.94 (cap hit 28x)
```

**Takeaways:**

1. **Token spend is bursty.** A single noisy alertname can blow the
   cap before useful signal arrives. Already mitigated with a
   `AI_IGNORE_ALERTS` deny list in the controller (commit pending
   alongside this doc).
2. **Most diagnoses are `noop`.** Phase 1 mostly tells us "yep,
   that alert isn't actionable — investigate manually." That's
   useful but doesn't reduce operator load — same number of
   manual investigations, just with more context to start from.
3. **Phase 2's value prop is real.** When the rule-based path can't
   match and Claude proposes a sensible `restart_pods` action, the
   user wants a one-click "approve" — not a manual `kubectl rollout
   restart` after reading the email.
4. **Cost is fine if we filter.** $0.94/day at cap is the upper bound.
   With the noise filter, projected steady state is ~$0.10-0.20/day.
   Phase 2 adds ~zero marginal cost. Phase 3 doesn't change call
   volume — just whether the controller waits for human approval.

## Phase 2 — Approve / Reject via email link

### Goal

Email diagnoses include `[Approve]` and `[Reject]` HTML buttons.
Clicking Approve causes the controller to execute the proposal
without further interaction. Reject records "false positive" in
audit log + cools down.

### Architecture

```
firing alert → controller → _advise() → diagnose +
  generate approval token + store proposal in pending map →
  email with two URLs:
    https://approve.etherport.net/?token=<HMAC>
    https://approve.etherport.net/?token=<HMAC>&action=reject

user clicks Approve →
  approval endpoint (NEW: small HTTP handler on the same controller pod) →
    validates HMAC, pulls proposal from pending map →
    executes via existing restart_pods() / scale_deployment() →
    audits + responds "approved + executed at HH:MM:SS"
```

### New components

1. **Approval endpoint** — new `GET /approve` handler in the same
   Python controller. Returns minimal HTML "Approved + executed"
   on success, or "Token expired/invalid" on failure. No frontend
   framework; one route, ~30 lines.

2. **Pending-proposals store** — in-memory dict keyed by
   `proposal_id = hash(alertname + ts + proposed_action)`. Lives
   for 24h then garbage-collected. Single-replica controller, so
   in-memory is fine. (Going multi-replica would need a Redis or a
   K8s ConfigMap backing.)

3. **HMAC signing** — new SOPS-encrypted secret
   `approval-hmac-secret.sops.yaml` holds a 32-byte random secret.
   The controller signs `proposal_id` with it; the approval URL
   carries `proposal_id + signature`; the handler re-signs to
   verify. Replay-resistant via ts + proposal expiry.

4. **Public ingress** — `approve.etherport.net` → controller
   service. Either: (a) Tailscale-only (your devices have TS, so
   approval works from phone/laptop without VPN), or (b) public
   ALB with auth gate (Cloudflare Access?). Recommendation: TS-only.
   Adding a public approval URL would change the threat model
   significantly.

5. **Email template change** — current plain-text email becomes
   text+HTML multipart. HTML version has the two buttons.

### Code paths to touch

- `platform/kubernetes/auto-remediation/controller-configmap.yaml`:
  - Add second `BaseHTTPRequestHandler.do_GET` for `/approve`
  - Add `_pending_proposals` dict
  - Add `_sign(proposal_id)` + `_verify(token)` HMAC helpers
  - Modify `_send_email` to send multipart with HTML buttons
  - On approve: dispatch to `restart_pods()` / `scale_deployment()`
    (same functions the rule-based path uses)
- `platform/kubernetes/auto-remediation/deployment.yaml`:
  - Mount the new HMAC secret as env
- `platform/kubernetes/auto-remediation/approval-hmac-secret.sops.yaml`:
  - New SOPS file with `hmac_key` (32 random bytes b64)
- `platform/kubernetes/auto-remediation/service.yaml`:
  - Already exposes 8080; just add an Ingress on a Tailscale domain
- `clusters/wind/ingress/` (or wherever Tailscale ingress lives):
  - New IngressRoute `approve.etherport.net` → service

### Milestones

1. **M41.P2.a** (2 days): controller code changes + unit-test the
   HMAC sign/verify locally. No deploy.
2. **M41.P2.b** (1 day): commit + Flux deploys; fire synthetic alert,
   verify email has HTML buttons + clicking Approve restarts the
   target pod end-to-end.
3. **M41.P2.c** (1 day): observe real alerts for a week; tune any
   awkwardness (e.g., approval links expiring too fast, HTML rendering
   in mobile mail).

### Exit criteria

- An advisor diagnosis with `proposed_action.type != noop` can be
  one-click approved from your phone (via TS) and executed within
  30 seconds.
- Rejected proposals get a `event=rejected` audit line.
- HMAC verifier rejects forged or expired tokens (verified via
  hand-crafted bad token in the smoke test).

### Open questions for Phase 2

- **Single-replica controller is a SPOF for the approval path.**
  If the pod restarts between email-sent and approve-click, the
  pending proposal is gone (in-memory). Acceptable for Phase 2
  since pod restarts are rare; move to ConfigMap-backed store if
  it bites.
- **Time-to-expiry of approval token.** Default 1h? 24h? Tradeoff:
  long expiry = action is taken on stale context.
- **Do we want a "snooze" option** that adds 30min to cooldown but
  doesn't reject outright? Maybe. Phase 2.5.

---

## Phase 3 — Autonomous execution (gated per-alert)

### Goal

For specific alerts pre-marked safe, the advisor executes
automatically if confidence is high enough — no email-and-wait.
You're notified after the fact.

### Trigger condition

ALL of:

1. `alert.labels.ai_remediation == "auto"` (explicitly opt-in
   per alert via Alertmanager rule labels)
2. `proposed_action.type in {restart_pods, scale_deployment_temp}`
   (no expansion of the allowlist for Phase 3)
3. `proposed_action.params.namespace not in AI_NAMESPACE_DENYLIST`
4. `proposed_action.confidence >= 0.85`
5. No action taken for same alertname in last 15min (cooldown)

If any condition fails: fall through to Phase 2 behavior
(email with Approve button).

### Architecture changes from Phase 2

Tiny. Phase 3 is a 30-line addition to the `_advise()` function
that checks the trigger conditions and bypasses the email-wait
path when they're all met.

The audit log emits a different event (`event=auto_executed`) so
you can grep for everything the AI did autonomously.

### Code paths to touch

- `platform/kubernetes/auto-remediation/controller-configmap.yaml`:
  - Add auto-execute path in `_advise()` between validation and
    email-send.
- `platform/kubernetes/monitoring/comprehensive-alerts.yaml`:
  - Add `ai_remediation: auto` labels to specific alerts ONE AT
    A TIME after operator confirms each alert is safe.

### Milestones

1. **M41.P3.a** (1 day): code path + first alert opted in
   (recommend: `NodeLocalDNSHighErrorRate` — already has a static
   rule but the static path is more conservative — Phase 3 lets the
   AI catch unusual variants).
2. **M41.P3.b** (ongoing): expand the opt-in list as confidence
   builds. Target 1 alert/week of expansion.

### Exit criteria

- At least one alert auto-executing for 30 days without operator
  having to manually override.
- Audit log shows zero false-positive auto-executions (defined as
  operator rolling back the AI's action within 5 min).

### Open questions for Phase 3

- **Should auto-execute have a kill switch?** A `kubectl set env
  deploy/remediation-controller AI_AUTO_EXECUTE=false` would
  immediately revert to Phase 2 behavior for all alerts. Yes —
  build this into Phase 3.
- **How to recover from a bad auto-execution.** If the AI restarts
  a pod and that makes things worse, we need a way to (a) detect,
  (b) revert. Detection = post-action verification via the same
  metric the alert fires on, with rollback if the metric stays
  red for 5min. Cleanest as a Phase 3.b enhancement, not v1.

---

## Dependencies + risks

### Hard dependencies

- **Tailscale** is already deployed for the approval URL. No new
  infra needed.
- **SOPS / age** for the HMAC secret. Already in use.
- **Existing alertmanager-config** routing already sends alerts to
  the controller via the webhook receiver. No AM changes needed.

### Risks

- **LLM regression.** If Anthropic ships a Claude version that
  starts producing malformed JSON or wrong action types, Phase
  2/3 fails silently (the controller falls back to advisory-only).
  Mitigation: structured-output validator rejects malformed
  responses + emails the user with "AI advisor unavailable" + raw
  alert. Same path as the cap-reached fallback today.
- **Approval URL phishing.** If an attacker spoofs an approval
  email and tricks the user into clicking, an arbitrary pod
  restart happens. Mitigation: HMAC tokens are bound to a
  specific proposal_id; an attacker can't forge a valid one
  without the HMAC secret. The email is from `ai-advisor@
  etherport.net` (DKIM-signed via SES) so spoofing is detectable.
- **Cost spike.** A new noisy alert could blow the cap. Already
  mitigated by `AI_IGNORE_ALERTS` (Phase 1) + the daily cap. If
  Phase 3 starts auto-executing wrong things, cap doesn't help
  — that's a Phase 3 risk specifically.

---

## Recommendation

**Build Phase 2 next.** Phase 1 produced useful diagnoses but no
ergonomic execution path — Phase 2 closes that loop. Phase 3 is
straightforward IF Phase 2 works; if Phase 2 reveals the diagnoses
aren't trustworthy enough to one-click approve, Phase 3 is moot.

ETA Phase 2: **~3-4 dev-days** spread across a week of real-alert
observation. Phase 3 follows ~1 day after Phase 2 stabilizes.

Phase 4 (feedback loop) sketched in the spec doc is the long-term
play — adds a "this was wrong" button on the email so we can
retrain prompts or convert recurring fixes into static rules.
Defer until Phase 3 is steady-state.
