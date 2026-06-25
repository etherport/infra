# Infra-agent prompt — cairn metrics cutover (M103)

> Hand this to the infra agent **when ready to cut the mini's backups over from the bash suite to
> cairn**. It covers the **infra-repo + cluster** work (Grafana dashboards, Prometheus alerts, Alloy
> log shipping, Pushgateway cleanup). The **mini-side** work (build/sign cairn, grant TCC, `cairn
> install`, unload the bash LaunchAgents) is done separately on the mini via the cairn session/VNC —
> see [`../runbooks/cairn-deployment.md`](../runbooks/cairn-deployment.md). Backed by a verified
> cross-repo audit (every consumer series accounted for).

## Context
cairn (repo `sparked-diamond/cairn`) replaces the mini's bash backup suite. **Decision: a clean
label-based metric schema** (not the legacy name-mangled `*_backup_*` / `photos_export_*`), so the
dashboards/alerts get rewritten to the new schema. cairn emits the schema below to the same
Pushgateway (`https://pushgateway.wind.etherport.net`), `instance="mini"`. Reporting must stay
consistent — every existing panel and alert gets a new-schema equivalent; nothing is dropped.

## The new cairn schema (what cairn emits — your rewrite target)
- **Per-job** (`{job, instance="mini"}`, job ∈ photos, contacts, calendars, reminders, notes, drive,
  messages, **messages_attachments**, **safari**):
  `cairn_backup_last_run_timestamp_seconds`, `cairn_backup_last_rc`, `cairn_backup_duration_seconds`,
  `cairn_backup_items`, `cairn_backup_bytes`.
- **Success-gated** (separate Pushgateway group so a failed run can't wipe it; carries
  `job="<job>_lastsuccess"`): `cairn_backup_last_success_timestamp_seconds`.
- **Photos** (`{job="photos"}`): `cairn_photos_summary_parsed`, `cairn_photos_total`,
  `cairn_photos_exported`, `cairn_photos_missing`, `cairn_photos_missing_unavailable`,
  `cairn_photos_missing_resolvable`, `cairn_photos_orphans`. (When a run is untrustworthy — killed /
  unparsed summary — the count family is **-1**, never a misleading 0; `summary_parsed=0`.)
- **Agent health** (`{job="cairn_health"}`): `cairn_up`, `cairn_heartbeat_timestamp_seconds`,
  `cairn_jobs_total|ok|failing|missing`, `cairn_healthy`, `cairn_oldest_run_age_seconds`,
  `cairn_oldest_success_age_seconds`.
- **Host health**: `mini_health_*` stays (still produced by `mini-health.sh` — do NOT remove).

## 1. Dashboards (`platform/kubernetes/monitoring/dashboards/`)
**`icloud-backups.yaml`** — template var `cat`: `label_values({__name__=~".+_backup_last_rc"}, job)`
→ `label_values(cairn_backup_last_rc{instance="mini"}, job)` (exclude `job=~".+_lastsuccess"`). Panels:
`${cat}_last_rc` → `cairn_backup_last_rc{job="$cat"}`; `${cat}_items` → `cairn_backup_items{job="$cat"}`;
`${cat}_duration_seconds` → `cairn_backup_duration_seconds{job="$cat"}`;
`${cat}_last_success_timestamp_seconds` → `cairn_backup_last_success_timestamp_seconds{job="${cat}_lastsuccess"}`.

**`photos-export.yaml`** — replace every `photos_export_*` with the new names:
`photos_export_last_rc`→`cairn_backup_last_rc{job="photos"}`; `_duration_seconds`→`cairn_backup_duration_seconds{job="photos"}`;
`_last_success_timestamp_seconds`→`cairn_backup_last_success_timestamp_seconds{job="photos_lastsuccess"}`;
`_exported`→`cairn_photos_exported`; `_missing_resolvable`→`cairn_photos_missing_resolvable`;
`_missing_unavailable`→`cairn_photos_missing_unavailable`; `_orphans`→`cairn_photos_orphans`;
`_photos_total`→`cairn_photos_total`. **Leave the Loki log panel `{host="mini"}` as-is** — but see §3
(cairn's logs must reach Loki with that label or it goes blank).

## 2. Alerts
**`09-photos-export-alerts.yaml`** (rename metrics; thresholds unchanged):
- PhotosExportFailed: `cairn_backup_last_rc{job="photos",instance="mini"} != 0`
- PhotosExportStale: `time() - max(cairn_backup_last_success_timestamp_seconds{job="photos_lastsuccess",instance="mini"}) > 129600`
- PhotosExportNoMetrics: `absent(cairn_backup_last_success_timestamp_seconds{job="photos_lastsuccess",instance="mini"})`
- PhotosExportNotParsed: `cairn_photos_summary_parsed{instance="mini"} == 0`
- PhotosExportCoverageRegressed: `cairn_photos_missing_resolvable{instance="mini"} > 0`
- PhotosExportOrphansGrowing: `delta(cairn_photos_orphans{instance="mini"}[26h]) > 50`

**`10-icloud-backups-alerts.yaml`** (templated `by (job)` over the `cairn_backup_*` family; exclude the
`_lastsuccess` pseudo-jobs):
- ICloudBackupFailed: `cairn_backup_last_rc{instance="mini",job!~".+_lastsuccess"} != 0`
- ICloudBackupStale: `time() - cairn_backup_last_success_timestamp_seconds{instance="mini"} > 129600`
  — keep the `label_replace(..., "(.+)_lastsuccess")` to map the job label back to the base category.
- **ICloudBackupEmpty (apply the audit's fix — add an rc-gate):**
  `cairn_backup_items{instance="mini",job!~".+_lastsuccess"} == 0 and on(job) cairn_backup_last_rc{instance="mini"} == 0`
  — without the `and on(job) ... last_rc == 0`, a `not_ready`/failed run (items=0, rc≠0) double-pages
  Empty **and** Failed. Only a *successful* run that backed up 0 items is genuinely "empty".

> Note: `cairn_backup_items` for messages/photos is a **file count** (not logical record count) — fine
> for the empty/health check; label the dashboard panel accordingly.

## 3. Alloy log shipping (`infra/macos/mini/alloy-config.alloy`)
cairn writes logs to `~/Library/Logs/cairn/*.log`. Add that path to the Alloy `local.file_match` /
loki source so cairn's logs ship to Loki with `host="mini"` (the photos-export dashboard's log panel
keys on `{host="mini"}`). Drop the old per-script log tails (photos-export, icloud-dav, messages,
icloud-files) once those scripts are retired.

## 4. Pushgateway cleanup (do AFTER cutover is verified)
The bash series are **persisted** in Pushgateway and won't be overwritten by the new names — they'd
linger frozen (stale dashboards + any leftover alert). Delete each old group:
```
for J in photos_export photos_export_resume photos_export_lastsuccess photos_export_resume_lastsuccess \
         contacts_backup calendars_backup messages_backup messages_attachments_backup notes_backup \
         safari_backup icloud_drive_backup \
         contacts_backup_lastsuccess calendars_backup_lastsuccess messages_backup_lastsuccess \
         messages_attachments_backup_lastsuccess notes_backup_lastsuccess safari_backup_lastsuccess \
         icloud_drive_backup_lastsuccess; do
  curl -fsS -X DELETE "https://pushgateway.wind.etherport.net/metrics/job/${J}/instance/mini" || true
done
```

## 5. Cutover sequence (safe, reversible)
1. **Prereq (mini, done in the cairn session):** cairn built/signed, TCC granted, `cairn install`
   loaded; confirm the new series exist: `curl -s https://pushgateway.../metrics | grep cairn_backup`.
2. **Add** the rewritten dashboards + alerts **alongside** the old ones (don't delete yet) → merge → Flux reconcile.
3. **Per category**, on the mini: unload the bash LaunchAgent (`launchctl unload <plist>`) and let
   cairn own it; verify the new `cairn_backup_*{job=...}` series populate and the new panel/alert work.
   Order: small/safe first (contacts, calendars, reminders, notes, safari, drive, messages), **photos last**.
4. After ALL categories verified: remove the **old** dashboards/alerts + retire the bash scripts/plists;
   run §4 Pushgateway cleanup; update Alloy (§3).
5. **Keep running:** `net.wind.mount-nas`, `net.wind.nsmb-install`, `net.wind.alloy`,
   `net.wind.mini-health` (update its expected-agents list to the cairn agents).
- **Rollback (any step):** re-enable the bash LaunchAgent (`launchctl load`), restore the old
  dashboard/alert (still in git until step 4) — the old bash series resume on the next run.

## Don't break these
- `06-backup-alerts.yaml` (homelab s3-sync / unifi / cnpg / velero / etcd) — **cluster-side, unrelated**; leave untouched.
- The `s3-sync` CronJob (`0 1 * * *`) — cairn jobs are scheduled to finish before it (same as the bash suite).
