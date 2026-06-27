# KubePodCrashLooping

Default kube-prometheus-stack alert. Fires when
`max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", job="kube-state-metrics", namespace=~".*"}[5m]) >= 1`,
i.e. a container has sat in `CrashLoopBackOff` at any point in the last
5-minute window. Severity: warning. (Custom homelab `PodCrashLooping` is
tuned tighter — see that runbook.)

## Symptom

A container has been in `CrashLoopBackOff` within the last 5-minute
window — the kubelet is backing off restarts because it keeps dying.

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
