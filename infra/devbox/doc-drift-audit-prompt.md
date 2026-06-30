You are running HEADLESS on the devbox for the WEEKLY live-anchored doc/IaC drift audit.
Repo: /home/ubuntu/code/infra (on `main`, auto-pushes). You have full local access: `kubectl`
(cluster-admin), the SOPS age key (`~/.config/sops/age/keys.txt`), the UDM API key + GitHub
dispatch PAT in the SOPS ops bundle, and on-host `ip route`.

## Goal
Find docs + IaC that **contradict LIVE state** — the "201-class" drift that no live-vs-IaC
diff (terraform plan / ansible --check) catches. **Auto-fix the high-confidence DOC cases;
report everything else.** Things change weekly, so this runs every week.

## ⚠️ Permission scope (you are running with a scoped allowlist, NOT skip-permissions)
You can read anything, **edit only `docs/**`, any `README.md`, and `CLAUDE.md`** (+ write your
artifacts under `~/.local/state/doc-drift-audit/`), run read-only commands, `git add/commit/push`,
and dispatch ONE GitHub workflow. `terraform`/`ansible` apply, `kubectl` mutations, `rm`/destructive
git, and edits to any `infra/`, `platform/`, `clusters/` file (other than READMEs) are **hard-denied**.
The bash matcher also **rejects `$(...)` command substitution and `VAR=x cmd` env-prefixes** — so:
- `SOPS_AGE_KEY_FILE` is already exported; just run `sops -d <file>` (no prefix, no `$()`).
- For ops that compose a secret into curl, use the **helper** (below) instead of hand-rolling.
- Run commands **stepwise** (read a value from one command's output, then inline it literally into
  the next) rather than capturing with `$(...)`.

## Method (live-anchored — compare to LIVE, never doc-to-repo)
Verify the checkable claims in `docs/architecture/*`, `docs/runbooks/*`, key component READMEs,
and `CLAUDE.md` against actual live state:
- `kubectl get/describe ...` for cluster/Flux/workload/namespace/label facts (read verbs only).
- **UDM API (read-only GET), via the helper** — `infra/devbox/audit-helpers.sh udm <endpoint>`
  (e.g. `udm networkconf`, `udm firewall-policies`, `udm portforward`, `udm routing`). The helper
  decrypts the key + curls internally, so the secret never hits the log. GET only.
- **IaC drift signal** — read the `drift-status` ConfigMap the continuous detectors write:
  `kubectl get configmap drift-status -n monitoring -o yaml` (each key is a detector → `status,timestamp`;
  `0`=clean, `1`=drift). This is the accessible source (the dispatch PAT can't read GitHub issues).
  `infra/devbox/audit-helpers.sh gh-get '<path>'` exists for Actions/Contents reads, but NOT issues.
- `ip route get <dst>` for routing/topology claims (the devbox is on VLAN 201).
- You MAY use the Workflow tool to fan the audit out across doc areas; a single thorough pass is fine too.

## Actions (in priority order)
1. **Auto-fix HIGH-CONFIDENCE doc drift** — a clear factual contradiction with live (a wrong
   IP / port / count / routing fact / retired-vs-current architecture). Edit the doc, then
   `git pull --rebase`, `git commit` (clear message; end with the standard
   `Co-Authored-By:` + `Claude-Session:` footer), `git push`. Group related fixes per commit and
   note each commit SHA. Apply the current-state/archive split convention (CLAUDE.md §6) when a
   doc has accreted migration narrative.
2. **Do NOT auto-change** IaC, ambiguous cases, or anything needing an apply/judgment — collect them.
3. **Write the email/issue artifacts** with the **Write tool** (the runner emails these EVERY run):
   - Write your full markdown summary body to `infra/devbox/.audit-state/last-summary.md` (this
     in-repo dir is gitignored + write-allowed; the Write tool is denied for out-of-repo paths). For
     a clean week a one-line "✅ clean — no doc/IaC drift" is fine. It MUST contain:
     - **Auto-fixed this run** — a bullet list of the KEY doc changes made, each with its commit SHA.
     - **Needs manual review** — IaC drift + ambiguous doc cases (file + what's wrong + the live value).
   - Write a single status word to `infra/devbox/.audit-state/last-status`: `clean` if nothing
     drifted, otherwise `drift`. (If you skip this, the runner still emails a log-tail fallback.)
4. **Publish to the `doc-drift` GitHub issue — via the helper** (the dispatch PAT can't post issues
   directly; the helper dispatches `post-doc-drift-issue.yml`, whose `GITHUB_TOKEN` does the posting):
   - drift: `infra/devbox/audit-helpers.sh dispatch-issue drift infra/devbox/.audit-state/last-summary.md`
   - clean: `infra/devbox/audit-helpers.sh dispatch-issue clean` — closes any open `doc-drift` issue.
   Always ALSO ensure the full summary is in your run log (it's the report of record).

## Safety (hard rules)
- **NEVER** run `terraform apply`, `ansible-playbook` (non-check), or any mutating infra command.
- **NEVER** touch secrets, delete files, or change IaC/manifests — this run edits **docs only**.
- If you're not sure a doc fix is high-confidence, **leave it for manual review** (report, don't edit).
- Keep total runtime under ~40 min.
