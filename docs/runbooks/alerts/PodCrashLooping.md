# PodCrashLooping

Fires when `increase(kube_pod_container_status_restarts_total[15m]) > 2`
sustained for 30 minutes. Severity: info (does NOT email under the
critical-only alertmanager route; visible in Grafana/Prometheus).
Tuned thresholds — see fix history.

## Symptom

A pod has restarted >2 times in a rolling 15-minute window AND is still
restarting 30 minutes later. Old/looser version of this rule was the
single largest source of paging noise (~hundreds of fires per day for
one-off OOMs that immediately self-recovered).

## Verified root cause(s)

- App bug: container's main process is panicking on startup or shortly
  after — check `kubectl logs <pod> --previous`.
- Liveness probe misconfigured (failing during startup before readiness
  is achieved) — check pod's probes vs actual startup duration.
- Resource pressure: container OOMKilled repeatedly. Pairs with
  `PodOOMKilled`. Fix via `bump_resource_request` (manual approval).
- Image / mount failure that the kubelet doesn't surface as
  ContainerWaiting (rare; usually one transient bad pull rather than
  steady-state crashloop).

## Fix history

- 2026-05-22 (commit 28c1c2c): Tightened expression from `rate > 0 /
  for: 5m / warning` to `increase > 2 / for: 30m / info`. Old version
  fired on ANY single restart anywhere; new version requires actual
  crashloop behavior.
- 2026-05-22 (commit cd208e5): Moved alertmanager email route to
  critical-only — PodCrashLooping at severity=info no longer emails,
  reducing noise while keeping the signal in dashboards.

## Verification steps

1. Current restart count + reason:
   `kubectl -n <ns> describe pod <pod>` (look at "Restart Count" and
   "Last State" / "Reason" fields).
2. Previous-container log:
   `kubectl -n <ns> logs <pod> --previous --tail=200`
3. After fix, watch restart count stabilize:
   `kubectl -n <ns> get pod <pod> -w` — restart count should stop
   incrementing for 15+ min.
4. Confirm in Prometheus:
   `increase(kube_pod_container_status_restarts_total{pod="<pod>"}[15m])`
   should return to 0.

## Advisor action guidance

- `restart_pods` — appropriate when logs show a transient init issue
  (config map race, dependent service warming up). Will let pod
  re-init cleanly. Confidence threshold is moderate.
- `rollback_deployment` — Tier 2 (manual approval). Appropriate when
  crashloop started immediately after a Helm/Flux roll.
- `bump_resource_request` — Tier 2. Use when logs show OOMKilled.
- `noop` is correct when logs show a clear app bug requiring code fix.
- For DaemonSets (esp. system pods in kube-system / flux-system /
  cert-manager), the namespace denylist blocks all actions — defer to
  operator.
