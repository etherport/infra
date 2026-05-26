# AI Advisor — Institutional-Learning Roadmap

How the advisor learns from past fixes and gets more robust over time.
Captures what's done, what's next, and the bar for "complete enough."

Last updated: 2026-05-25.

## What's live today

| Mechanism | Where | What it gives Claude |
|---|---|---|
| Past actions on the same alert (7d) | `_past_actions_for_alert()` → `ctx.history.past_actions` | The advisor's own prior attempts: action type, params, verification outcome. Surfaces repeat-failures so Claude can change tack. |
| Closed-loop verification | `_schedule_verification()` → Loki audit | Outcome of each action recorded as `verification_passed` / `verification_failed` events. Becomes input to the next round's past_actions. |
| Per-action confidence calibration | `AI_PHASE3_ACTION_THRESHOLDS` dict | Risky actions (restarts, replica reseeds) require higher confidence than cleanup actions. Encoded judgment from incidents. |
| `search_git_log` tool (deep mode) | `_tool_search_git_log()` | Searches commit messages via GitHub API. Lets Claude find the commit that fixed a recurring alert last time. |
| `read_runbook` tool (deep mode) | `_tool_read_runbook()` | Reads `docs/runbooks/alerts/<alertname>.md` if it exists — operator-curated fix recipes that beat first-principles reasoning. |

## Roadmap — items not yet built

Tracked separately from main task list since these are advisor-internal R&D.

### R1 — Structured commit trailers convention (guide landed 2026-05-26)

**Status:** Convention documented at [commit-trailers.md](commit-trailers.md). Adoption ongoing — every new fix-commit should include the trailers; back-filling old commits is not worth the effort.

**Problem.** `search_git_log` works on free-text commit messages today. Search quality depends on whether the author happened to mention the alert name. Misses are common.

**Solution.** Adopt commit-trailer convention for any commit that fixes an advisor-relevant issue:

```
<commit subject>

<body>

Fixes-alert: VeleroLastBackupAgeHigh
Root-cause: Global label-less metric series stuck; alert matched it
Action-pattern: Filter expr with {schedule!=""}
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Then `search_git_log` can grep with `--grep="Fixes-alert: <name>"` precisely — no keyword guessing.

**Scope.**
- ~3 lines of documentation in `CONTRIBUTING.md` (or top of `docs/runbooks/auto-remediation/README.md`).
- Possibly a commit-msg hook that prompts for the trailer when relevant files are touched (`platform/kubernetes/monitoring/*.yaml`, `auto-remediation/*`).
- Update `search_git_log` tool docstring to mention the trailer convention so Claude prefers it.

**Effort.** ~1 hr. Mostly habit-formation, not code.

**ROI.** Compounds. Every new fix-commit becomes precisely searchable. After ~6 months, most advisor-relevant repo history is structured.

### R2 — Mount memory files into the advisor

**Problem.** The assistant has `~/.claude/projects/-Users-grahamsmith-code-infra/memory/*.md` — distilled cross-session learnings (python-kubernetes v31 auth bug, UDM zone-policy quirks, PVE ansible model, etc.). These are exactly the kind of context that prevents repeat investigation. The advisor doesn't see them.

**Solution.**
1. Curate a subset suitable for the advisor (reference-type memories about infra quirks; skip user-preference / session-state ones).
2. Sync to a ConfigMap `auto-remediation/advisor-knowledge` (manual sync script or weekly CronJob that rsyncs the subset).
3. Mount at `/etc/advisor-knowledge/`.
4. Add tools `list_knowledge_files()` + `read_knowledge_file(name)` mirroring `read_runbook`.
5. Update advisor prompt: "Before investigating obscure failures, check list_knowledge_files for any matching reference notes."

**Scope.**
- Curation criteria + initial sync (~20 files → maybe 8 keepers).
- ConfigMap mount in deployment.yaml (~15 lines).
- 2 new tool entries + dispatch (~40 lines in `controller-configmap.yaml`).
- Prompt update (~5 lines).
- Sync mechanism: simplest = manual `kubectl create configmap --from-file=...` documented in a runbook; better = a make target.

**Effort.** ~half day for v1 (manual sync). ~1 day if automating the sync.

**ROI.** High for obscure infra-specific gotchas. Lower for general programming knowledge (Claude already knows that).

**Open question.** Do we want this to be one-directional (advisor reads operator-curated knowledge) or bidirectional (advisor *adds* observations to a separate "advisor-learned" store)? Start one-directional. Reconsider after 30 days of usage data.

### R3 — Manual-fix capture loop

**Problem.** When the operator fixes something manually (outside the advisor's action set), the advisor never sees it. Past_actions only captures advisor attempts. Half the institutional knowledge is invisible.

**Solution paths (pick one):**

- **a) Passive — commit-trailer convention catches it** (per R1). If every manual fix-commit has `Fixes-alert:` and `Root-cause:`, then `search_git_log` recovers it automatically. Cheapest. Relies on discipline.
- **b) Active — `record-fix` CLI.** A small CLI (`bin/record-fix VeleroLastBackupAgeHigh --action "manual:filter-fix" --notes "..."`) that writes a structured entry to a store the advisor reads (Loki line with a specific label set, or a JSON file in the repo). Slightly heavier.
- **c) Post-hoc — assistant-session memory sync.** When the user fixes something in a Claude Code session, the assistant prompts "save this as a learned fix?" at session end. Writes to the same store as (b). Requires the assistant to track this — current memory system handles this informally already.

**Recommendation.** Do (a) first — comes free with R1. If it proves insufficient after a few months, add (b) as a thin wrapper.

**Effort.** 0 incremental if going with (a) + R1. ~1 day for (b).

### R4 — Robustness improvements to existing actions

Independent of learning, but related to "make actions more reliable." Listed for completeness.

| Improvement | Effort | Value |
|---|---|---|
| Per-action frequency caps (e.g., `delete_completed_jobs` max 5x/day per alert) | ~20 lines | Prevents runaway loops if Claude misjudges |
| Dry-run mode for risky actions (`rollback_deployment`, `cnpg_recreate_replica`) — show what'd happen, require explicit re-approve | ~50 lines | Operator sees actual impact before committing |
| Pre-flight checks before execute (verify target exists + expected state) | ~30 lines per action | Catches stale Claude diagnoses |
| Post-execute output capture (stdout/stderr into audit log) | ~10 lines per action | Better forensics when verification fails |
| Self-tuning thresholds: if `verification_failed` count > N for (alert, action) pair, auto-raise that action's confidence threshold | ~40 lines | Closes the calibration loop without manual intervention |

**Priority.** Frequency caps + self-tuning thresholds are highest value. Dry-run mode is high value for the highest-risk actions but adds operator friction — only worth it for irreversible ones.

### R5 — Backfill `docs/runbooks/alerts/*.md` for recurring alerts

**Problem.** Today only `VeleroLastBackupAgeHigh.md` exists. `read_runbook` returns "not found" for everything else, making the tool nearly inert.

**Solution.** Write seed runbooks for every alert that has fired more than once in the last 90 days. Use a Prom query to enumerate. Template each as:

```
# AlertName

## Symptom
<what fires + why it pages>

## Verified root cause (most recent)
<from the commit that fixed it last time>

## Fix history
- YYYY-MM-DD <commit-hash>: <one-line summary>

## Verification steps
<how to confirm the fix worked>

## Advisor actions
<which of the 18 action types are appropriate; which to avoid>
```

**Effort.** ~10 min per runbook. Maybe 15-20 recurring alerts → ~3 hrs total. Can be agent-delegated.

**ROI.** Multiplies R-zero (read_runbook) from "barely used" to "called for every alert." Highest immediate-leverage item on this list.

## Sequencing recommendation

1. **R5** (backfill runbooks) — immediate, makes `read_runbook` actually useful. Half-day, agent-delegatable.
2. **R1** (commit trailers) — adopt convention. Zero code; just habit.
3. **R4 frequency caps + self-tuning** — defensive layer. Day's work.
4. **R2** (mount memory files) — once R5 proves the read-tool pattern works.
5. **R3** (manual-fix capture) — only if R1 doesn't catch enough.

## Success criteria

The system is "learning well" when:
- ≥80% of recurring-alert investigations cite `read_runbook` or `search_git_log` results in the advisor email body
- Repeat-failure rate (`verification_failed` count per alert) trends down month-over-month
- The operator stops being surprised by the advisor's diagnoses on familiar alerts — "yes, that's what last time was about" should be common.
