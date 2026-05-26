# PodOOMKilled

Fires on `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1`
for 1 minute. Severity: info (kept in Grafana, does not email under the
critical-only route).

## Symptom

A container exited with reason OOMKilled. By itself this is usually
not page-worthy — the kubelet restarts the pod and workload resumes.
The alert is kept around for trend analysis and to surface
slow-burn memory leaks that don't trip `PodCrashLooping`.

## Verified root cause(s)

- Memory leak in the app (slow climb until OOM, repeats every few hours
  or days).
- Memory limit set too low for actual workload (steady-state usage
  near limit; bursts push it over).
- One-off memory spike from a large request / scrape / import job.
- JVM/Go heap not tuned to the cgroup limit (less common, but a known
  cause for older Java apps).

## Fix history

- 2026-05-22 (commit 28c1c2c): Severity dropped warning → info. Old
  version paged on every single OOM; new version is observational.
  Sustained crashloop from OOM still pages via `PodCrashLooping`.

## Verification steps

1. Confirm the kill:
   `kubectl -n <ns> describe pod <pod>` — "Last State: Terminated /
   Reason: OOMKilled / Exit Code: 137".
2. Memory usage history:
   `kubectl top pod -n <ns> <pod>` (instant) or Prometheus:
   `container_memory_working_set_bytes{pod="<pod>"} / container_spec_memory_limit_bytes`
3. Was the kill chronic? Count over 24h:
   `count_over_time(kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}[24h])`
4. After raising the limit, watch for at least one full natural cycle
   (typically 24h) to confirm no more OOMs.

## Advisor action guidance

- Preferred (Tier 2, manual approval): `bump_resource_request`. The
  action records the previous/new request in the audit log so revert
  is straightforward.
- `restart_pods` is unnecessary — the kubelet already restarted it.
- `noop` is fine for one-offs (no recurrence in 24h).
- Don't propose `scale_deployment_temp` — adding replicas doesn't help
  per-pod memory issues.
