# CNPGBackupFailed

Fires when `cnpg_collector_last_failed_backup_timestamp` is newer than
`cnpg_collector_last_available_backup_timestamp` for any CNPG cluster.
Severity: critical (deep-mode advisor investigation). No auto-action.

## Symptom

PrometheusRule `backup-jobs / cnpg-backup.rules / CNPGBackupFailed`
firing for a postgres cluster. The most recent attempted Barman backup
failed AND that failure post-dates the last successful one — i.e. the
cluster is currently in a "broken backups" state, not just a stale one.

## Verified root cause(s)

- Operator/network/storage path to S3 (Backblaze B2 endpoint) broken:
  expired access key, B2 outage, MTU/SDN regression on egress path.
- Barman backup pod scheduled on a node without egress (rare; SDN
  misconfig).
- Underlying postgres cluster bug — primary unhealthy, WAL archive
  failing. Often pairs with `cnpg_pg_replication` alerts.
- PromQL match-group duplicate-series error (silently kept the rule
  inert, masking real failures) — fixed 2026-05-24.

## Fix history

- 2026-05-24 (commit cc02cc3): Wrapped both sides of the `>` comparison
  in `max by (cluster, namespace)(...)` so the rule no longer fails
  with "duplicate series for match group" — every CNPG pod publishes
  duplicate timestamps, which the bare `> on (...)` rejected.
- 2026-05-22 (commit f5aa1e3): Initial M46 backup-coverage addition
  (this rule was authored).

## Verification steps

1. Confirm rule itself is healthy:
   `kubectl -n monitoring get prometheusrules backup-jobs -o yaml | grep -A2 CNPGBackupFailed`
   and the Prometheus targets page for `PrometheusRuleFailures`.
2. List recent Backup objects:
   `kubectl -n postgres get backups --sort-by=.metadata.creationTimestamp`
3. Describe the most-recent failed Backup:
   `kubectl -n postgres describe backup <name>` — surfaces Barman
   error (S3 4xx, network timeout, WAL archive backlog).
4. Check the cluster's WAL archive status:
   `kubectl -n postgres get cluster <name> -o jsonpath='{.status.conditions}'`
5. Trigger a manual backup once root cause is fixed:
   `kubectl -n postgres cnpg backup <cluster> --backup-name=manual-$(date +%s)`

## Advisor action guidance

- Marked `ai_advisor_mode: "deep"` in the alert rule — Claude should
  tool-use (kubectl, Loki, `search_git_log`) to investigate before
  proposing anything.
- `trigger_cnpg_backup_now` is NOT useful here — re-running a broken
  backup gives the same failure. Save it for `CNPGBackupStale` where
  the issue is just a missed window.
- `noop` + detailed recommendation is the most common correct outcome.
- Avoid `cnpg_recreate_replica` for backup failures — that's for
  replica drift / replication failure, not backup failure.
