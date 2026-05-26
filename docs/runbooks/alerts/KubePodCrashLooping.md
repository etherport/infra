# KubePodCrashLooping

Default kube-prometheus-stack alert. Fires when
`rate(kube_pod_container_status_restarts_total[15m]) * 60 * 5 > 0`
sustained 15 min, i.e. >1 restart in the last 5-minute window.
Severity: warning. (Custom homelab `PodCrashLooping` is tuned tighter —
see that runbook.)

## Symptom

A pod has restarted at least once within the last 5-minute window and
this remained true for 15 minutes — meaning restart pattern is steady,
not a one-off.

## Verified root cause(s)

Same set as the custom `PodCrashLooping`:
- App bug: container's main process panicking on startup or shortly
  after.
- Liveness probe misconfigured (failing during startup).
- Memory pressure → OOMKilled in a loop (pairs with `PodOOMKilled`).
- Image / config / mount failure on every pod start.

## Fix history

- See `PodCrashLooping.md` — most homelab fixes targeted the custom
  rule, which is the one that emails. The kube-prometheus default
  was not modified (it stays warning + on the Prometheus rules page).

## Verification steps

Same as `PodCrashLooping.md`:
1. `kubectl -n <ns> describe pod <pod>` (Restart Count + Last State)
2. `kubectl -n <ns> logs <pod> --previous --tail=200`
3. Watch restart count via `-w`; should stop incrementing.

## Advisor action guidance

- Same as `PodCrashLooping`. Prefer `restart_pods` for transient init
  issues, `rollback_deployment` (Tier 2) for post-roll crashloops,
  `bump_resource_request` (Tier 2) for OOM patterns. `noop` if logs
  show a clear app bug.
- If both `KubePodCrashLooping` and `PodCrashLooping` fire on the
  same pod, treat them as one alert — don't double-act.
