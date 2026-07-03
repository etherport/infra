# Agent operating principles — the durable charter

How this repo is operated, written down so the discipline survives a change of
agent, model, or tooling. **These rules are tool- and model-agnostic**: they assume
only an agent that can read this repo, run shell commands, and talk to the operator.
Orientation (what to read first, credentials, invariants) lives in `CLAUDE.md`;
this file is *how to behave*. Rules, not essays. Each principle carries one real
example from this repo's history — the rule earned its place.

---

## A. Change discipline

**A1. Git is the only real state.** If it's not in git, it doesn't survive a rebuild —
and it will bite someone later. *Example:* ceph-csi ran 50 days as an out-of-band
`kubectl apply` whose config pointed at a pre-migration monitor IP; adopting it into
git (M120) defused a landmine that would have broken all new volume ops.

**A2. The plan must be exactly the intended diff.** Before any `terraform apply` or
ansible full-reconcile, review the plan/`--check --diff` output and apply only if it
contains your change and nothing else. Anything unexpected = stop and investigate.
*Example:* the travel-VPN teardown applied only after the plan read exactly
`1 to destroy`; the UniFi stack's cardinal rule is plan = `0 to add/change/destroy`.

**A3. One concern per commit; the message says *why* and carries the tracker ID.**
History is the recovery mechanism — a future agent greps it.
*Example:* `ci(diag): add runner-egress playbook to reveal CI runner's public egress IP (M110)`.

**A4. Validate before you commit.** `kubectl kustomize` the overlay; `kubectl apply
--dry-run=server` against live CRDs; check the gitleaks allowlist after any doc move
(see A6). CI validates too, but CI runs after the push to a Flux-watched branch.

**A5. Destroy/irreversible actions require verified-empty preconditions.** Confirm
the thing is unused *from live state*, not from docs. *Example:* both regional-VPN TF
workspaces were verified to hold 0 resources before the stack was deleted.

**A6. Moving or renaming a file means fixing every inbound reference in the same
change.** Grep for the old path: doc links, `.gitleaks.toml` allowlist paths, code
comments. *Example:* archiving an allowlisted doc turned secret-scan red on every
push until the path was repointed.

**A7. If you must touch live state directly, reconcile IaC in the same session and
say so.** A hand-edit that isn't persisted is drift with a fuse. *Example:* the M110
UDM `dhcp_dns` PUTs (provider 400 workaround) were immediately paired with
`ignore_changes` + a comment naming live-UDM as source of truth for that field.

**A8. Respect automation frictions instead of fighting them.** Run patch + rollout
as separate commands (compound commands trip the permission classifier); let the
push-triggered plan finish before dispatching an apply (S3 state-lock contention);
a killed run can leave a stale `.tflock` — clear it deliberately, don't retry blindly.


**A8. Version ladders are sequential-with-anchors.** When a component documents
no-skip upgrades (CNPG minors, Authentik majors), ladder one step at a time, take a
restore anchor before the first irreversible migration (DB backup + WAL/PITR, etcd
snapshot), and verify per hop (migration-under-lock completed, replicas Ready, 0
restarts) before the next. *Example:* CNPG 1.24→1.30 (6 hops) and Authentik
2024.12→2026.5 (8 hops) both landed clean this way on 2026-07-02/03; the
known-dangerous RBAC migration was de-risked by verifying its precondition
(`ak shell`: group-name uniqueness) BEFORE the hop.

**A9. Terraform identity changes are state surgery, not source edits.** A rename =
`moved {}` blocks (verified: plan shows moves + in-place, never destroy/create). A
provider swap across a schema rewrite CANNOT use `replace-provider` (the new provider
can't read the old schema's state → plans replacement of live resources); the safe
recipe is state-backup → `state rm` → rewrite `.tf` to the new schema → `import`
under the new types → iterate plan to zero, pinning config to LIVE values.
*Example:* M128 (moved{}) and M125 (import migration; two failed swap attempts were
cleanly reverted by a reverse replace-provider before the recipe was applied).

## B. Verification bar — what "done" means

**B1. Never trust "apply succeeded" — verify the live result.** The exit code proves
the tool ran, not that the change landed. *Example:* M91 — `terraform apply`
"succeeded" and rebooted the VM, but the watchdog device never appeared; ~7 reboots
were wasted chasing a no-op. M118 — a HelmRelease carried resource requests that
never landed in the rendered pods.

**B2. Exercise the change end-to-end (an acid test), not just its components.**
*Example:* the ceph-csi namespace move was accepted only after a full
PVC provision→attach→mount→write→delete through the moved stack.

**B3. Use positive and negative controls.** Prove the new path works AND the old
path fails / the forbidden path is blocked. *Example:* M76 was "done" when certs
worked on all 15 hosts *and* the static key was demonstrably REJECTED.

**B4. "No drops observed" only covers the paths you exercised.** Before flipping any
observe→enforce switch, deliberately exercise the real external/ingress paths.
*Example:* a netpol tier validated as "0 audit drops" still took the Traefik VIP
down for 16h because the world→VIP path was never exercised during the window.

**B5. Green CI is a signal, not a verdict.** Confirm the *right* run succeeded and
read its output. *Example:* polling "latest completed run" after a dispatch grabs
the same-SHA push-plan run, whose success masks the apply's failure — filter
`event=workflow_dispatch`.

**B6. Adversarially review your own substantive work before calling it done.**
Assume it's wrong and try to break it. *Example:* the review of the unattended-audit
permissions overturned the entire allowlist design (shell redirection bypassed path
scoping); the backup-suite review found 4 CRITICAL bugs, one scheduled to run that
night.

**B7. Right-size and tune from measured data, not intuition.** Query the actual
P95/max over a real window and cite it in the commit. *Example:* M118 set prometheus
requests from "P95 1.83Gi vs the old 2Gi limit — <10% from OOM".


**B6. Verify redundancy CONVERGES, not just that each half runs.** Two healthy
keepaliveds can still split-brain if the control protocol between them is blocked; a
standby whose daemon is dead is not a standby. After changing anything on a failover
path (firewall, image, script), run the actual failover drill and watch BOTH
directions (takeover AND reclaim). *Example:* 2026-07-03 — M77's default-deny
silently dropped VRRP (IP proto 112) into vpn-fallback for five days; the design
looked healthy until the first real failover produced a VIP split-brain. The drill
(kill pod → 9s VM takeover → 300s pod reclaim) is now the acceptance test.

**B7. Long-running operations run in detached tmux, monitored via their log file.**
Harness-managed background tasks can be killed mid-operation; a cluster upgrade or
state migration must survive that. *Example:* the 2026-07-02 kubespray run was killed
mid-download as a background task and completed flawlessly in tmux.

## C. Diagnosis discipline

**C1. Localize the layer first: timeout vs refused.** A connect **timeout** means a
firewall/network drop (SYN swallowed); **refused** means the host answered and the
process is dead. This distinction picks which of the FOUR connectivity layers (UDM
zones, PVE host firewall, Cilium netpol, CF Access/Authentik — CLAUDE.md §5) to
check. A drop at any layer looks identical from the client — check all four.

**C2. Vary one variable; prove the negative.** *Example:* the same source IP had SSH
dropped while WG-UDP flowed cleanly in the same window ⇒ path loss, not the instance;
small payloads 20/20 while scrapes flapped would have implicated MTU.

**C3. When a prior diagnosis turns out wrong, say so explicitly — in the tracker and
session log, marked as a CORRECTION.** The wrong theory is a datum future debugging
needs. *Example:* "⚠️ CORRECTION: the 'flap' is a homelab↔AWS PATH packet-loss issue,
NOT the box's ENA … the resize is still justified for RAM, but it is not the flap fix."

**C4. Distinguish tool artifacts from real failures.** Know what your check can't
see. *Example:* `base.yml --check` fatals on "service chrony not found" because the
install task only *simulated* — a check-mode artifact, not a bug; `technitium.yml`
fails in `--check` by design and is unsuitable for drift detection.

**C5. Work around a lossy path with retries, but root-cause it as a separate
thread.** *Example:* M110's cert bootstrap shipped via a retry loop + SSH
ControlPersist over the intermittent path while the path loss became its own
investigation — the workaround never closed the underlying question.

**C6. Observe before you enforce — always.** Any new deny/enforce boundary goes
through observation against *real* traffic first: netpol tiers (the audit toggle),
Kyverno (Audit→Enforce), PSA labels (`--dry-run=server`), VM firewalls (ACCEPT+log
before DROP). And remember the enforced-tier tax: a service crossing an enforced
boundary needs that tier's allowlist updated in the same change (the M110 dns-sync
:5380 sync was POLICY_DENIED for exactly this).


**C7. "It worked before" may mean "it won a race before".** A component that
functioned for weeks can be latently broken and surviving on a startup race, a
conntrack entry, or a stale ARP/cache. When a restart breaks something old, suspect
the ordering, not (only) the change that restarted it. *Example:* the WG pod's
HOST_IP script ran 50 days only because it usually started before keepalived claimed
the VIP; 2026-07-02's recreation lost the race and exposed the bug.

**C8. Stored config can drift from live config — re-assert on any reset.** Helm
stored values vs ConfigMap hand-patches, TF state vs console edits, blueprints vs UI
changes: any "reset-then-reuse" style operation re-materializes the STORED truth.
Enumerate hand-patched knobs and re-assert them in the same command. *Example:*
cilium `--reset-then-reuse-values` re-enabled policyAuditMode (would have silently
un-enforced 6 netpol tiers); caught in post-upgrade verify, now baked into the
cilium-upgrade runbook.

## D. Documentation & memory discipline

**D1. Docs are part of the change.** A change isn't done until every doc it
invalidates is updated — component READMEs, runbooks, architecture docs, indexes —
in the same change or an immediate follow-up commit (CLAUDE.md §6 is the checklist).

**D2. Archive, don't delete; banner, don't contradict.** Superseded docs move to the
sibling `archive/` with a status banner. Live reference docs stay
**current-state-only**; migration narrative moves to
`archive/<topic>-migration-history.md` (exemplar: `firewall-zones.md` + its twin).

**D3. Work items keep stable IDs forever.** New items take the next free ID per tier
(H/M/L) in `docs/planning/outstanding-work.md`; IDs are never reused, so history is
grep-able — `M110` means the same thing in every file, forever.

**D4. Every substantive session ends with a handoff.** Tracker glyphs flipped, a
session-log entry (what/why/state/next steps, newest first, commit SHAs), and
durable non-obvious facts saved to the per-machine agent memory with a pointer in
its `MEMORY.md`. Assume the next session starts with zero chat history.

**D5. Report residuals honestly in the tracker.** A ✅ with an open edge is a ✅ plus
an explicit "⚠️ residual:" line — open work must never go invisible inside a done item.

## E. Safety rails

**E1. Secrets exist only encrypted (SOPS+age) or in the operator's stores.** Never
commit plaintext, never paste a secret into logs/issues/summaries/emails. Render
throwaway creds only when needed and shred them after (`render-aws-credentials.sh`
pattern). `op` does not work from agent shells — ask the operator, don't retry.

**E2. Some credentials are load-bearing: rotate, never delete.** *Example:* the
`terraform-homelab` IAM key is shared with the local debug profile. When in doubt
about a key's blast radius, ask first.

**E3. Unattended automation gets least privilege, with mutation in a trusted
wrapper, not the agent.** A prefix allowlist cannot enforce "docs-only, no exfil"
(redirection, write-flags, `git push` all bypass it). *Example:* the weekly
doc-drift agent has no git/curl/sops; its wrapper stages doc paths only,
secret-scans, and owns commit/push.

**E4. Know the break-glass path before you need it.** PVE console + IPMI
`10.10.200.21` for SSH/cert failures; SSM for the AWS edge box; `akadmin` for
Authentik. Document the revert (the commit to `git revert`, the workflow to
re-dispatch) alongside any risky change.

**E5. Before rebooting/draining a node, clear the known wedges.** Delete PDB-blocked
single-instance CNPG pods first (RBD won't unmount); patch cp1 LAST; verify etcd
quorum between control-plane steps. Check the runbook before inventing a procedure.

## F. Operator interaction

**F1. Ask first for: irreversible/destructive actions, spending or cost-profile
changes, security-posture *reductions*, credential lifecycle changes, and anything
requiring a UI/console the agent can't reach.** Proceed autonomously on reversible,
in-scope work — then report. An operator approval in one context does not extend to
the next ("delete the travel VPN" ≠ "delete things generally").

**F2. Report failures and uncertainty as prominently as successes.** State what is
unverified and what would prove it. If evidence is insufficient, say so explicitly
rather than guessing — and attach an honest confidence to diagnoses.

**F3. When you and the operator disagree, show the evidence.** *Example:* the cost
investigation disproved the storage-transition hypothesis with object-count data
before proposing the real fix (request-cost from hourly Kopia maintenance).


**F6. Peer-agent handoffs carry evidence, not summaries.** When work crosses into
another agent's repo/domain (the s3-backup app, the personal-web zones), hand over a
prompt containing: the precise failing artifact paths (report keys, run IDs), what
was already verified on this side, and the boundary (what they own vs what stays
here). *Example:* the 2026-07-03 multipart-ETag finding shipped with the exact
report path + the confirmation that the bytes were verified complete in S3.

## G. Model-agnostic contract

**G1. The repo beats your memory, and your memory beats your training.** On any
conflict: live state > repo docs > per-machine memory > what you think you know.
Read `CLAUDE.md` §1's files and the newest session-log entry before acting.

**G2. Verify tool availability; don't assume your predecessor's environment.**
No `flux` CLI, no standalone `kustomize`, no `gh` on the devbox (dispatch via the
M92 PAT/REST), no working `op` from agent shells. Probe before use; record new
capability facts in `CLAUDE.md` §4 when they change.

**G3. Leave the trail a *different* agent can follow.** Write session-log entries,
commit messages, and corrections for a reader with no access to your chat history,
your tooling, or your model. If a step only you could reproduce, it isn't done.
