# KubeJobFailed

Fires when a Kubernetes Job's `status.failed` exceeds the BackoffLimit
without any subsequent success. Default kube-prometheus-stack alert.
Severity: warning. Auto-eligible action: `delete_completed_jobs`.

## Symptom

PrometheusRule `kube-prometheus-stack-kubernetes-apps / KubeJobFailed`
firing — often for many job_names at once. Each Job lives forever by
default; once one fails, the alert series persists until the Job object
is deleted. A single bad CronJob can produce hundreds of stuck Job
records → hundreds of firing alerts → email flood (this was the dominant
contributor to the ~4k-email incident #37 P1).

## Verified root cause(s)

- CronJobs without `ttlSecondsAfterFinished` set — failed Job records
  accumulate forever. The alert groups by `job_name` (unique per Job),
  so each historical failure stays firing indefinitely.
- A CronJob with a real underlying bug (image pull failure, missing
  secret, NFS mount failure, expired credential) producing a new
  failed Job on every schedule tick.
- `cloudflare-ddns` and other every-minute CronJobs amplify either of the
  above into a flood.

## Fix history

- 2026-05-23 (commit 52a145f): Bump `ttlSecondsAfterFinished` from 1h
  to 25h on s3-sync CronJobs — 1h was too aggressive (daily-report
  couldn't enumerate the run), but the 1h had successfully cleared the
  Job pile-up.
- 2026-05-22 (commit f1751dc): Add `ttlSecondsAfterFinished: 3600` to
  every CronJob's jobTemplate cluster-wide. Cleared the bulk of the
  KubeJobFailed flood.
- 2026-05-22 (commit cd208e5): Restricted alertmanager email route to
  severity=critical only (KubeJobFailed is warning → no more emails
  from this alert, though it still appears in Grafana/Prometheus).

## Verification steps

1. Count current failed Jobs:
   `kubectl get jobs -A --field-selector=status.successful=0 -o wide`
2. Confirm the offending CronJob has `ttlSecondsAfterFinished`:
   `kubectl get cronjob <name> -n <ns> -o jsonpath='{.spec.jobTemplate.spec.ttlSecondsAfterFinished}'`
3. For an underlying-bug case, look at the most recent failed pod logs:
   `kubectl -n <ns> logs job/<job-name>`
4. Confirm alert clears in Prometheus:
   `count(kube_job_failed > 0)` should drop after Jobs are GC'd.

## Advisor action guidance

- Preferred: `delete_completed_jobs(namespace=<ns>, selector=<label>)`
  — clears stuck Job records, alert clears, no destructive impact.
- If the CronJob is producing fresh failures every schedule tick, the
  advisor should NOT just delete-jobs in a loop. Switch to `noop` with
  recommendation to investigate the failing pod's logs.
- `pause_cronjob` is appropriate (manual approval) if the underlying
  bug is known and unfixable in the moment (e.g., credential
  expired and rotation requires operator action).
- Avoid `restart_pods` — Jobs don't have long-lived pods to restart.
