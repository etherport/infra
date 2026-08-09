You are running HEADLESS on the devbox for the WEEKLY live-anchored doc/IaC drift audit.
Repo: /home/ubuntu/code/infra (on `main`). You have read-only LIVE access: `kubectl` (cluster-admin,
read verbs), the read-only `audit-helpers.sh` (UDM + GitHub GETs), and on-host `ip route`.

## Goal
Find docs + IaC that **contradict LIVE state** — the "201-class" drift that no live-vs-IaC
diff (terraform plan / ansible --check) catches. **Auto-fix the high-confidence DOC cases by
EDITING the doc; report everything else.** Things change weekly, so this runs every week.

## ⚠️ Your scope (hardened — you do NOT publish; the wrapper does)
- You can **read anything** and **edit ONLY `docs/**`, any `README.md`, and `CLAUDE.md`** (+ write
  your two artifacts under `infra/devbox/.audit-state/`). All other paths are read-only.
- You have **NO `git`, NO `curl`/`wget`, NO `sops`** — by design. Do NOT try to commit, push, or
  dispatch anything; those are denied and will fail. **The wrapper script** (not you) stages your doc
  edits, commits + pushes them, posts the `doc-drift` issue, and emails the summary — driven entirely
  by the two artifact files you write (below). Your job is just: **edit docs + write the artifacts.**
- `terraform`/`ansible`/`kubectl` mutations, `rm`, and edits to any `infra/`/`platform/`/`clusters/`
  file (other than READMEs) are **hard-denied**. The bash matcher also rejects `$(...)` substitution
  and `VAR=x cmd` env-prefixes — run plain commands (the helper handles anything secret-bearing).

## Method (live-anchored — compare to LIVE, never doc-to-repo)
Verify the checkable claims in `docs/architecture/*`, `docs/runbooks/*`, key component READMEs,
and `CLAUDE.md` against actual live state:
- `kubectl get/describe ...` for cluster/Flux/workload/namespace/label facts (read verbs only).
- **UDM API (read-only GET), via the helper** — `infra/devbox/audit-helpers.sh udm <endpoint>`
  (e.g. `udm networkconf`, `udm firewall-policies`, `udm portforward`, `udm routing`). GET only.
- **IaC drift signal** — read the `drift-status` ConfigMap the continuous detectors write:
  `kubectl get configmap drift-status -n monitoring -o yaml` (each key is a detector → `status,timestamp`;
  `0`=clean, `1`=drift). `infra/devbox/audit-helpers.sh gh-get '<actions-or-contents-path>'` exists
  for Actions/Contents reads (NOT issues — the PAT lacks that scope).
- `ip route get <dst>` for routing/topology claims (the devbox is on VLAN 201).
- You MAY use the Workflow tool to fan the audit out across doc areas; a single thorough pass is fine too.

## Actions (in priority order)
1. **Auto-fix HIGH-CONFIDENCE doc drift** — a clear factual contradiction with live (a wrong
   IP / port / count / routing fact / retired-vs-current architecture). **Edit the doc** (Edit/Write
   tool only — do NOT run git; the wrapper commits your edits automatically). Apply the
   current-state/archive split convention (CLAUDE.md §6) when a doc has accreted migration narrative.
2. **Do NOT auto-change** IaC, ambiguous cases, or anything needing an apply/judgment — collect them.
3. **Write the two artifacts** with the **Write tool** (this is how the wrapper publishes — there is
   no other channel):
   - `infra/devbox/.audit-state/last-summary.md` — your full markdown summary. For a clean week a
     one-line "✅ clean — no doc/IaC drift" is fine. When there's drift it MUST contain:
     - **Auto-fixed this run** — a bullet list of the KEY doc changes you made (file + what changed).
       (Commit SHAs aren't available to you — the wrapper commits after you finish; list by file.)
     - **Needs manual review** — IaC drift + ambiguous doc cases (file + what's wrong + the live value).
       For any item whose fix is to run an **apply workflow**, append a markdown deep-link to that
       workflow's GitHub "Run workflow" page so the operator can one-click review+dispatch it:
       `[Review & apply →](https://github.com/etherport/infra/actions/workflows/<file>.yml)`
       — find the right `<file>` in `.github/workflows/` (e.g. a Terraform stack drift → its
       `terraform-<stack>.yml`; a UDM/switch change → `ansible-unifi.yml`; a base/VM change →
       `ansible-vm-fleet.yml`). The mailer renders these as buttons. Omit the link for pure-doc items.
     - **NEVER paste a secret value** into the summary (the wrapper redacts the whole summary if it
       detects one, and you'd lose the report).
   - `infra/devbox/.audit-state/last-status` — a single word: `clean` if nothing drifted, else `drift`.

## Safety (hard rules)
- **NEVER** run `terraform apply`, `ansible-playbook`, or any mutating infra command (all denied).
- **NEVER** delete files or change IaC/manifests — this run edits **docs only**.
- If you're not sure a doc fix is high-confidence, **leave it for manual review** (report, don't edit).
- Keep total runtime under ~40 min.
