# Auto-Remediation System

Two layers in one namespace:

1. **Static rule-based remediation** — 22 hardcoded alert→action
   mappings in `configmap.yaml` (restart_pods / scale_deployment).
   Hits first; deterministic; the floor.
2. **AI advisor (Phases 1/2/3 live)** — handles alerts that fall
   through the static rules. 18 action types across 3 tiers,
   closed-loop verification, cross-session memory, deep-mode tool-use.

Both run in the same controller pod (image: `python:3.14-slim`,
pip-installs `kubernetes pyyaml boto3 paramiko` on start).

## Flow

```
PrometheusRule → Alertmanager → webhook (this controller)
  ├── static rule match? → execute (after 15-min cooldown check) → email + audit
  └── no match → AI advisor:
        ├── Phase 1 only? → email diagnosis (no action)
        ├── Phase 2 + actionable? → email with Approve/Reject HMAC buttons
        ├── Phase 3 + label opt-in + confidence + allowlist? → auto-execute + email receipt
        └── after auto/approve-execute → schedule verification re-check N min later
              ├── alert cleared? → verification_passed
              ├── alert still firing? → verification_failed → email operator
              └── ambiguous? → verification_uncertain
```

## Components

- **Namespace**: `auto-remediation`
- **Service**: `remediation-webhook` (ClusterIP, port 8080) — Alertmanager target
- **Tailscale Ingress**: `remediation-approve.<tailnet>.ts.net` — Approve/Reject URLs
- **Public Ingress** (alt): `https://approve.etherport.net` via Traefik (current default APPROVAL_BASE_URL); ready to route through CF Tunnel after the NS-cutover
- **ConfigMaps**:
  - `remediation-rules` (`configmap.yaml`) — static alert→action mappings
  - `remediation-script` (`controller-configmap.yaml`) — controller Python; this is the real source of truth, the legacy `controller.py` placeholder is unused
  - `ai-advisor-prompt` (`advisor-prompt-configmap.yaml`) — system prompt, action-type taxonomy, guardrails
- **Secrets** (all SOPS):
  - `ai-advisor-anthropic-key` — Anthropic API key
  - `ai-advisor-approval-hmac` — HMAC signing key for Approve URLs
  - `ai-advisor-aws-cloudwatch` — read-only CW Logs (M45 Phase B)
  - `advisor-ssh-key` — Tier 3 SSH key (deployed to dns-aws/dns-fallback/vpn-local/vpn-aws)
- **RBAC**: ServiceAccount + ClusterRole for pod/deployment patching across denylisted-namespaces-excluded set

## Files

| File | Role |
|---|---|
| `namespace.yaml` | Namespace |
| `rbac.yaml` | SA + ClusterRole + binding |
| `service.yaml` | ClusterIP for the webhook |
| `deployment.yaml` | Controller deploy (env vars set Phase 1/2/3 toggles) |
| `configmap.yaml` | Static rule-based remediation rules |
| `controller-configmap.yaml` | Real controller Python (~2400 lines) |
| `advisor-prompt-configmap.yaml` | System prompt + action taxonomy |
| `approval-ingress.yaml` | Tailscale Ingress |
| `approval-public-ingress.yaml` | Traefik public Ingress for `approve.etherport.net` |
| `*.sops.yaml` | Secrets (SOPS-encrypted) |
| `COVERAGE.md` | What static rules + advisor cover, where the gaps are |
| `README.md` | This file |

(The `controller.py` file in this directory is a stub from the original Phase 0 design and is not referenced by the deployment; the real controller lives in `controller-configmap.yaml` and is mounted as `/scripts/remediate.py`.)

## Deployment

Managed by Flux (`clusters/wind/kustomization.yaml`). Changes via
git → push → reconcile.

To force a reload after editing rules:

```bash
kubectl annotate -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl rollout restart deploy/remediation-controller -n auto-remediation
```

## Management

### View logs
```bash
kubectl logs -n auto-remediation -l app=remediation-controller --tail=50
# Or: structured audit events
kubectl logs -n auto-remediation deploy/remediation-controller | grep ai_advisor
```

### Disable temporarily
```bash
# Disable the advisor only (static rules keep working):
kubectl set env deploy/remediation-controller -n auto-remediation \
  AI_ADVISOR_ENABLED=false
# Or kill all execution by scaling to zero:
kubectl scale deployment -n auto-remediation remediation-controller --replicas=0
```

(Both are point-in-time overrides; Flux reverts on next reconcile.)

## Safety features

- **15-min cooldown** per (alertname, action). Prevents flap-spam restarts.
- **Namespace denylist**: `kube-system`, `flux-system`, `cnpg-system`, `cert-manager`, `rook-ceph` — Phase 3 auto-execute downgrades to email if target is in this list.
- **Action allowlist** for Phase 3: `noop`, `restart_pods`, `scale_deployment_temp`. SSH-tier auto-eligible actions are similarly tightly bounded.
- **Confidence threshold**: Phase 3 requires Claude confidence ≥ `AI_PHASE3_CONFIDENCE_THRESHOLD` (default 0.85) to auto-execute; lower falls back to approve-via-email.
- **HMAC-signed approval links**: tokens bound to specific proposal_id, expire in 24h.
- **Closed-loop verification**: every auto/approve execute is re-checked N min later; verification_failed emails the operator.
- **Cross-session memory**: prior failed attempts on the same alertname surface in the prompt to discourage re-proposing actions that didn't work.
- **Daily cost cap**: `AI_ADVISOR_DAILY_COST_USD_CAP=$0.50` hard ceiling; at cap, advisor silently falls back to raw-alert emails.

## Alertmanager integration

Configured in `../monitoring/03-alertmanager-config.yaml`. All
critical alerts hit both `email-alerts` and `auto-remediation`
receivers (continue: true).

## Documentation

- Coverage: `COVERAGE.md` (this directory)
- Phase 1 enable: `docs/runbooks/ai-advisor-phase1-enable.md`
- Phase 2 enable: `docs/runbooks/ai-advisor-phase2-enable.md`
- Phase 3 enable: `docs/runbooks/ai-advisor-phase3-enable.md`
- Phase B (CW logs): `docs/runbooks/ai-advisor-phase-b-cloudwatch.md`
- Design spec: `docs/planning/ai-alert-remediation-2026-05-23.md`
- Phase 2/3 scope: `docs/planning/ai-advisor-phases-2-3-scope.md`
