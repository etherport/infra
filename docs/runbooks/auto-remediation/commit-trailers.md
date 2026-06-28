# Commit-trailer convention for advisor-relevant fixes

When a commit fixes (or partially fixes) a Prometheus alert, an
advisor regression, or anything else the AI advisor might re-encounter
later, add structured **git trailers** to the commit message body.

This gives every fix-commit a stable token (e.g. `Fixes-alert:
KubeJobFailed`) so the advisor's `search_git_log` tool — backed by the
GitHub Search API, which does keyword/token matching, not exact
`git log --grep` — reliably matches every commit that has ever touched
that alert, instead of guessing free-text keywords.

## Trailers

Place these at the bottom of the commit body, immediately above the
`Co-Authored-By:` line. Use the same format as standard git trailers
— one line, `Key: Value`.

```
<commit subject>

<body explaining why + what>

Fixes-alert: <AlertName>                # required when the commit
                                         # resolves an alert
Root-cause: <one-line summary>           # one sentence, verb-led
Action-pattern: <action_type>            # the advisor action that
                                         # fixed it, if any
Tags: <comma-separated topical labels>   # e.g., velero, cnpg, dns

Co-Authored-By: ...
```

Multiple trailers are fine — if one commit fixes two alerts, add two
`Fixes-alert:` lines. If the root cause is the same for both, write
one `Root-cause:` line.

## Example

```
monitoring: filter Velero last-backup metric to scheduled series

The VeleroLastBackupAgeHigh alert was firing perpetually because
the global `velero_backup_last_successful_timestamp` series (no
schedule label) was stuck at the oldest value. Real per-schedule
series were healthy. Fix: add `{schedule!=""}` to the alert expr.

Fixes-alert: VeleroLastBackupAgeHigh
Root-cause: Global label-less metric series never updates; alert matched it
Action-pattern: filter_expr
Tags: velero, backup, prometheus
```

## Why

- **`search_git_log` precision.** The advisor calls this tool when an
  alert has fired before (its `past_actions` history has entries).
  It's backed by the GitHub Search API (token/keyword matching), not a
  local `git log --grep`. Without trailers, queries rely on free-text
  keywords against commit subjects + bodies — high recall, low precision.
  With trailers, the stable `Fixes-alert: <X>` token reliably surfaces
  the relevant history.

- **Operator searchability.** `git log --grep="Fixes-alert:" --all` is
  a one-liner audit of every alert-fixing commit in repo history.

- **Cheap to adopt.** Three extra lines per fix-commit. No code change.
  Existing commits without trailers still work via free-text search; the
  trailer convention compounds value over time.

## When NOT to add trailers

- Pure-feature commits (new playbook, new module) — no alert in scope.
- Doc-only commits, unless they're updating an alert runbook (then a
  `Tags: runbook, <AlertName>` line helps).
- Renames + mechanical refactors.

## Validation

Optional commit-msg hook to nudge trailers when the diff touches
advisor-relevant paths. Lives in `.git/hooks/commit-msg` (not in repo;
local-only):

```bash
#!/usr/bin/env bash
# Warn (don't block) if the diff touches monitoring/alerts and the
# commit body has no Fixes-alert: trailer.
diff_paths=$(git diff --cached --name-only)
needs_trailer=false
echo "$diff_paths" | grep -qE 'monitoring/.*alerts|loki-rules' && needs_trailer=true
if $needs_trailer; then
  grep -q 'Fixes-alert:' "$1" || echo "💡 Consider adding 'Fixes-alert: <Name>' trailer (commit-trailers.md)"
fi
exit 0
```

## Related

- Advisor's `search_git_log` tool: `platform/kubernetes/auto-remediation/controller-configmap.yaml` (search for `_tool_search_git_log`)
- Learning roadmap: `learning-roadmap.md` (this is the R1 entry)
