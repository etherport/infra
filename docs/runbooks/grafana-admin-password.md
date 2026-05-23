# Grafana admin password — reset to match the secret

When chart-defined `admin.password` (or `admin.existingSecret`) doesn't
agree with what's in Grafana's own sqlite DB. Symptoms:

- `grafana-sc-dashboard` sidecar log spam: every minute it tries
  `POST /api/admin/provisioning/dashboards/reload` and gets `401
  password-auth.failed`
- Grafana log: `Failed to authenticate request` from `auth.client.basic`
- After enough failed attempts: `too many consecutive incorrect login
  attempts for user - login for user temporarily blocked` — the admin
  user is rolling-locked out of the UI too
- New dashboards STILL appear in the UI (file provisioner scans
  `/tmp/dashboards/` every 30s independently), but the human admin login
  doesn't work and the log noise drowns out real signal

## Why this happens

The kube-prometheus-stack `grafana` subchart sets the admin password
via the `GF_SECURITY_ADMIN_USER` + `GF_SECURITY_ADMIN_PASSWORD` env
vars (sourced from the SOPS secret
`platform/kubernetes/monitoring/grafana-admin-secret.sops.yaml`).
**Grafana only applies these env vars on first-ever startup with an
empty DB** — on subsequent startups it reads the password hash from
`/var/lib/grafana/grafana.db`. So if anyone changes the password via
the UI (or if the chart's secret is rotated after the DB exists), the
env var stops matching reality.

## The fix

```
kubectl -n monitoring exec deploy/monitoring-grafana -c grafana -- /bin/sh -c \
  'grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD"'
```

This re-hashes the env-var password and writes it to the DB. Idempotent;
safe to re-run. Within 60s the sidecar's next reload should return
`200 OK` instead of `401`. Verify:

```
kubectl -n monitoring logs deploy/monitoring-grafana -c grafana-sc-dashboard --tail=3
# expect "Response: 200 OK" lines, not 401
```

## When to run this

- **After cluster rebuild** if the previous DB doesn't carry forward.
- **After rotating the SOPS-encrypted admin password** (the new
  password lives in the secret but Grafana's DB still hashes the old
  one until reset).
- **After someone changes the password via the UI** — the chart wants
  to be the source of truth, so re-aligning makes the sidecar happy.

## Why we don't just `kubectl edit grafana.db` or auto-reset every fire

A CronJob that resets the password every N minutes would intrude on
legitimate UI changes; an init container would only fire on pod
restart (not on secret rotation). Manual is the right tradeoff for
how rarely the trigger happens. If we get tired of the manual step,
add a sentinel-checked Job that reads a hash of the secret and only
resets when it differs from a stored hash.

## History

- 2026-05-23 — fix applied during alert audit; sidecar had been 401ing
  every minute for ~5 days, rolling-blocking the admin user. Caught
  while investigating M22 dashboard appearance. M26 in
  `docs/planning/outstanding-work.md`.
