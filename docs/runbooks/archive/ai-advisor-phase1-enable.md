# AI Advisor (M41 Phase 1) — Enable Runbook

Phase 1 = **advisory-only**. The advisor sees alerts that fall through
the static rule dispatch, diagnoses likely cause, proposes an action,
and **emails the diagnosis to you**. It never executes anything in
Phase 1.

Code is deployed (commit `062b3b1`, 2026-05-23) with
`AI_ADVISOR_ENABLED=false`. This runbook turns it on. Reverting to
off is a single env-var flip + apply.

Design spec lives at `docs/planning/ai-alert-remediation-2026-05-23.md`.

## Prerequisites

You need 3 things before turning the toggle:

1. **An Anthropic API key.** Recommend a **dedicated** key for billing
   isolation so you can see this workload's cost separately from any
   personal Claude.ai usage. Create at:
   <https://console.anthropic.com/settings/keys>. Anthropic doesn't
   expose key creation via the public API — you have to log in and
   click the button.

2. **SES SMTP credentials.** Mirror of the values in
   `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml`:
   `smtp_auth_username` (the AKIA* key) + `smtp_auth_password`
   (the SES SMTP password from 1P "AWS — SES SMTP" item).
   K8s Secrets are namespaced so we have to copy them rather than
   mount cross-namespace.

3. **`sops` CLI installed locally** (already in your homelab tooling).
   Confirm: `which sops`.

## Steps

### 1. Populate the Anthropic API key

```bash
sops platform/kubernetes/auto-remediation/anthropic-api-key.sops.yaml
```

Replace `REPLACE_WITH_REAL_KEY` with the key you just created. Save
+ close the editor — sops re-encrypts on save.

### 2. Populate the SMTP credentials

```bash
sops platform/kubernetes/auto-remediation/smtp-credentials.sops.yaml
```

Replace both `REPLACE` placeholders. Easiest path: open
`platform/kubernetes/monitoring/alertmanager-secret.sops.yaml` in
another shell with `sops`, copy the two values across, save both.

### 3. Flip the toggle

Edit `platform/kubernetes/auto-remediation/deployment.yaml` and change:

```yaml
- name: AI_ADVISOR_ENABLED
  value: "false"
```

to:

```yaml
- name: AI_ADVISOR_ENABLED
  value: "true"
```

### 4. Commit + push

Flux will reconcile within ~1min (or annotate to force-reconcile).

```bash
git add platform/kubernetes/auto-remediation/
git commit -m "M41: enable AI advisor Phase 1"
git push
kubectl annotate -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

The remediation-controller pod will restart with the new env.

### 5. Verify

```bash
# Pod env should now show AI_ADVISOR_ENABLED=true
kubectl get deploy remediation-controller -n auto-remediation \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AI_ADVISOR_ENABLED")].value}'

# Startup log should announce ai_advisor=on
kubectl logs -n auto-remediation deploy/remediation-controller | head -5
```

Look for:
```
Auto-remediation webhook server listening on port 8080 \
  (ai_advisor=on, daily_cap=$0.5, model=claude-sonnet-4-6)
```

### 6. Wait for an alert that doesn't match a static rule

Or force one for testing — e.g., temporarily lower a Prometheus
alert threshold so it fires. Audit log:

```bash
kubectl logs -n auto-remediation deploy/remediation-controller \
  | grep ai_advisor
```

In Grafana / Loki:

```logql
{namespace="auto-remediation"} |= "ai_advisor"
```

Expected fields per call: `event=start`, `event=success`,
`alertname=...`, `confidence=...`, `cost_usd=...`,
`daily_usd_spent=...`. The diagnosis is emailed to
`graham.m.smith@me.com` (configurable via `EMAIL_TO` env).

## Tuning knobs (env on the deployment)

| Env | Default | What it does |
|---|---|---|
| `AI_ADVISOR_ENABLED` | `false` | Master switch |
| `AI_ADVISOR_DAILY_COST_USD_CAP` | `0.50` | Hard cap; at cap, falls back to emailing raw alert |
| `AI_ADVISOR_MAX_INPUT_TOKENS` | `8000` | Per-request budget (rough; not enforced inside `_build_context`) |
| `AI_ADVISOR_MODEL` | `claude-sonnet-4-6` | Bump to opus only if Sonnet diagnoses are weak |
| `EMAIL_TO` | `graham.m.smith@me.com` | Recipient |
| `EMAIL_FROM` | `ai-advisor@etherport.net` | Sender (uses SES verified domain) |

## Cost expectations

At ~5 advisor invocations/day (current alert volume that misses rules),
estimated **~$0.17/day, ~$5/mo**. The hard cap is `$0.50/day`; at cap
the advisor silently falls back to "advisory unavailable" + raw alert
in email.

If cost surprises happen, check the audit log:

```logql
sum by (alertname) (
  count_over_time({namespace="auto-remediation"} |= "ai_advisor" |= "event=success" | json [1d])
)
```

A flapping alert hitting the advisor every 15min (cooldown floor)
adds up. Add a static rule for it in
`platform/kubernetes/auto-remediation/configmap.yaml` to remove it
from the advisor path entirely.

## Rolling back

Two options:

- **Disable advisor only:** flip `AI_ADVISOR_ENABLED=true` → `"false"`
  in deployment.yaml, commit, push. The rule-based path keeps working.
- **Full revert:** `git revert 062b3b1` reverts the entire advisor +
  syslog labeling commit. Rule-based controller goes back to silently
  dropping non-matching alerts.

## Phase 2/3 — for later

Phase 2 adds Slack/email approval buttons before executing proposed
actions. Phase 3 adds an `auto` mode for allowlisted action types
above a confidence threshold. See the spec doc for the full plan.

Phase 1 is the validation step: does Claude actually produce useful
diagnoses on YOUR alert stream? Run for 1-2 weeks, then evaluate
whether the diagnoses were accurate enough to trust execution in
Phase 2/3.
