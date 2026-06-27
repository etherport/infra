# Alert runbooks

One file per Prometheus alert, named **`<PrometheusAlertName>.md`** (exact
`alert:` name, e.g. `S3SyncFailed.md`). Each captures: symptom, verified root
cause(s), fix history, verification steps, advisor action guidance.

The auto-remediation AI advisor loads the matching file at runtime via its
`read_runbook` tool (`docs/runbooks/alerts/<alertname>.md`), so an operator-curated
recipe here beats first-principles reasoning. Keep the filename exactly equal to the
alert name or the advisor won't find it.
