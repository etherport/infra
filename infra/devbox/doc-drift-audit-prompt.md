You are running HEADLESS on the devbox for the WEEKLY live-anchored doc/IaC drift audit.
Repo: /home/ubuntu/code/infra (on `main`, auto-pushes). You have full local access: `kubectl`
(cluster-admin), the SOPS age key (`~/.config/sops/age/keys.txt`), the UDM API key + GitHub
dispatch PAT in the SOPS ops bundle, and on-host `ip route`.

## Goal
Find docs + IaC that **contradict LIVE state** — the "201-class" drift that no live-vs-IaC
diff (terraform plan / ansible --check) catches. **Auto-fix the high-confidence DOC cases;
report everything else.** Things change weekly, so this runs every week.

## Method (live-anchored — compare to LIVE, never doc-to-repo)
Verify the checkable claims in `docs/architecture/*`, `docs/runbooks/*`, key component READMEs,
and `CLAUDE.md` against actual live state:
- `kubectl` for cluster/Flux/workload/namespace/label facts.
- UDM API (read-only GET only): `KEY=$(SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d
  infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | grep '^udm_api_key:' | sed -E 's/^udm_api_key: *//;s/"//g')`,
  then `curl -sk -H "X-API-Key: $KEY" 'https://10.10.200.1/proxy/network/api/s/default/rest/<endpoint>'`
  (networkconf, portforward, firewall-policies, routing). GET ONLY.
- `ip route get <dst>` for routing/topology claims (the devbox is on VLAN 201).
- The open `tf-drift` / `ansible-drift` / `cluster-config-drift` GitHub issues for IaC drift signal.
- You MAY use the Workflow tool to fan the audit out across doc areas; a single thorough pass is fine too.

## Actions (in priority order)
1. **Auto-fix HIGH-CONFIDENCE doc drift** — a clear factual contradiction with live (a wrong
   IP / port / count / routing fact / retired-vs-current architecture). Edit the doc, then
   `git pull --rebase`, `git commit` (clear message; end with the standard
   `Co-Authored-By:` + `Claude-Session:` footer), `git push`. Group related fixes per commit and
   note each commit SHA. Apply the current-state/archive split convention (CLAUDE.md §6) when a
   doc has accreted migration narrative.
2. **Do NOT auto-change** IaC, ambiguous cases, or anything needing an apply/judgment — collect them.
3. **Publish a summary** to the `doc-drift` GitHub issue. ⚠️ The dispatch PAT is Actions:write only
   (it 403s on `/issues`), so do NOT POST `/issues` directly — instead **dispatch the
   `post-doc-drift-issue.yml` workflow** (its `GITHUB_TOKEN` has issues:write):
   `POST .../actions/workflows/post-doc-drift-issue.yml/dispatches` with
   `{"ref":"main","inputs":{"clean":"<true|false>","summary_b64":"<base64 of the markdown body>"}}`
   using the dispatch PAT (`github_dispatch_pat` in the SOPS ops bundle). The markdown body MUST contain:
   - **Auto-fixed this run** — a bullet list of the KEY doc changes made, each with its commit SHA.
   - **Needs manual review** — IaC drift + ambiguous doc cases (file + what's wrong + the live value).
   If nothing drifted, dispatch with `clean:"true"` (no summary needed) — that closes any open `doc-drift`
   issue. Always ALSO write the full summary to your run log (it's the report of record).
4. **Write the email artifacts** (the runner emails these to the operator EVERY run, clean or drift):
   - Write your full markdown summary body to `~/.local/state/doc-drift-audit/last-summary.md`
     (same content as the issue body; for a clean week a one-line "✅ clean — no doc/IaC drift" is fine).
   - Write a single status word to `~/.local/state/doc-drift-audit/last-status`: `clean` if nothing
     drifted, otherwise `drift`. (If you skip this, the runner still emails a log-tail fallback.)

## Safety (hard rules)
- **NEVER** run `terraform apply`, `ansible-playbook` (non-check), or any mutating infra command.
- **NEVER** touch secrets, delete files, or change IaC/manifests — this run edits **docs only**.
- If you're not sure a doc fix is high-confidence, **leave it for manual review** (report, don't edit).
- Keep total runtime under ~40 min.
