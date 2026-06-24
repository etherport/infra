# Backup Agent (`cairn`) — moved to its own repo

`cairn` is a standalone product and lives in its own repo:
**https://github.com/sparked-diamond/cairn** (cloned at `~/code/cairn` alongside this one).

- **Canonical design** (architecture, rationale, build milestones): `cairn/DESIGN.md`.
- **Decision summary:** native **macOS Swift** app that backs up iCloud categories (Photos via
  PhotoKit, Calendars/Reminders via EventKit, Contacts via the Contacts framework, Messages/Notes/
  Safari/Drive via SQLite/file) to a NAS, with `rsync` (orchestrated by Swift `TaskGroup`) as the
  mirror engine. Going native removes the bash suite's failure modes (iCloud CalDAV/CardDAV
  rate-limiting, app-password/sops, osxphotos/vdirsyncer fragility). YAML config; four notifiers
  (Prometheus, SES email, ntfy/Pushover push, webhook); one-shot + daemon; per-app TCC + signing.
- **Metrics stay drop-in compatible** with the current dashboards/alerts; migration is incremental
  + reversible (run in parallel to a staging dest, cut categories over one at a time).

**This repo's role:** once `cairn` is built, its **deployment on the mini** gets documented here
(a runbook under `docs/runbooks/` + the launchd/TCC/signing setup), the same way every other
homelab component is. The per-category bash suite in `infra/macos/mini/` stays until `cairn`
reaches parity, then is retired. Tracked as **M103** in [`outstanding-work.md`](outstanding-work.md).
