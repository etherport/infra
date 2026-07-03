# devbox — Claude Code dev host (Linux)

devbox (`10.10.201.45`, ansible `playbooks/devbox.yml`, always-on Ubuntu VM, no
FileVault gate) hosts the Claude Code **dev sessions** (cue, personal-web,
infra), migrated off the Mac mini so they survive mini reboots and are
remote-controllable from claude.ai. The mini keeps the macOS-only work (Photos/iCloud).

## What's on the box (current toolset)
- `kubectl` (cluster-admin kubeconfig)
- `sops` + the age key (`~/.config/sops/age/keys.txt`) — headless `sops -d`
- `git`, `claude`
- `terraform` 1.15.5 + `aws` CLI — **throwaway/local-debug only** (M82: TF is
  CI-only; no standing AWS/PVE creds — re-render on demand via
  `scripts/render-aws-credentials.sh` / `scripts/tf-proxmox.sh`)
- `helm` v3.19 (`~/.local/bin`) — Cilium upgrades run from here
- kubespray venv at `~/.kubespray-venv` (ansible 11 / core 2.18) — cluster
  runs via `infra/kubespray/kubespray.sh` with
  `KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert`, long runs in detached tmux

Still lacks: a browser (headless-Chrome verification → mini/CI) and the `gh`
CLI (dispatch workflows via the M92 PAT + REST API instead, see below).

## Why devbox over the mini for sessions
- No FileVault unlock-on-reboot gate → genuinely unattended auto-resume.
- System `node`/`claude`/`tmux`/`git` in `/usr/bin` → works under systemd's minimal env.
- On the tailnet + LAN; RC works (Claude Code v2.1.154+ fixed Linux remote control).

## Auth (one-time, already done)
Claude Code OAuth login is broken on headless Linux (GitHub #47152 — "Missing
redirect_uri"), so devbox was authed by **transplanting the mini's full-scope token**
into `~/.claude/.credentials.json` (mini stores it in the macOS Keychain, service
`Claude Code-credentials`). Also had to set `hasCompletedOnboarding: true` in
`~/.claude.json` or interactive claude re-runs the setup/login wizard. If auth ever
breaks (token refresh issues), re-transplant from the mini; the real fix is Anthropic
patching #47152 so a normal `claude /login` works.

## GitHub workflow dispatch (drift sweeps / CI applies) — set up (M92)
The devbox has no `gh` CLI and no `GH_TOKEN`/`GITHUB_TOKEN`/`~/.config/gh`, but an
agent here **can `workflow_dispatch`** (run the drift sweep, trigger a `terraform …
apply`, etc.) over the GitHub REST API via a **fine-grained PAT** stored in the SOPS
ops bundle under `github_dispatch_pat`.

The PAT is scoped to **only `sparked-diamond/infra`** with **Repository permissions →
Actions: Read and write** (+ Contents: Read; Metadata: Read is automatic) — the minimum
to list + dispatch workflows. (A classic PAT with `repo`+`workflow` also works but is
far broader — avoided.)

> ⚠️ NOT the ARC-runner token. `platform/kubernetes/github-actions-runner/secret.sops.yaml`
> holds a `github_pat_…` (fine-grained) PAT for **runner registration only** — it
> does not have Actions:write and must not be repurposed for dispatch.

The PAT lives in the SOPS ops bundle
`infra/ansible/playbooks/secrets/homelab-ops.sops.yaml` under the key
`github_dispatch_pat`. An agent dispatches via the API (these snippets already read
that key):
```sh
TOK=$(SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d \
  infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | yq -r .github_dispatch_pat)
# run the daily drift sweep on demand:
curl -fsS -X POST -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/sparked-diamond/infra/actions/workflows/terraform-drift-detection.yml/dispatches \
  -d '{"ref":"main"}'
# apply ONE k8s VM (rolling — see outstanding-work M91):
curl -fsS -X POST -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/sparked-diamond/infra/actions/workflows/terraform-proxmox-k8s-vms.yml/dispatches \
  -d '{"ref":"main","inputs":{"action":"apply","target":"proxmox_virtual_environment_vm.workers[\"k8s-w4\"]"}}'
```
**ZT note:** this lets the devbox agent **trigger CI applies = mutate all infra** —
another blast-radius step on top of the age key already here (M82). Accepted
deliberately at M92; revoke the `github_dispatch_pat` to roll it back.

## Session migration (mini → devbox)
Transcripts copied from `~/.claude/projects/-Users-grahamsmith-code-<repo>/` →
`-home-ubuntu-code-<repo>/`. Gotchas:
- `claude --continue` won't resume a freshly-copied transcript (no lastSessionId on
  this machine) → resume each **once via `claude --resume` (picker)** in the correct
  repo dir; after that `--continue` follows it.
- The repo dir **must exist** at `~/code/<repo>` or `tmux -c` falls back to `$HOME`
  and claude opens the wrong project. The resume script auto-clones if missing.

## Reboot persistence
- `resume-claude-sessions.sh` — ensures each repo is cloned, then starts a detached
  tmux session per repo running `claude --continue` (self-healing, idempotent).
- `claude-sessions.service` — systemd **user** unit (oneshot, `WantedBy=default.target`)
  that runs the script at boot.

Install on devbox (one-time):
```bash
git -C ~/code/infra pull
chmod +x ~/code/infra/infra/devbox/resume-claude-sessions.sh
mkdir -p ~/.config/systemd/user
ln -sf ~/code/infra/infra/devbox/claude-sessions.service ~/.config/systemd/user/claude-sessions.service
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable claude-sessions.service
sudo loginctl enable-linger ubuntu      # so the user manager runs at boot without login
```
Verify / test:
```bash
systemctl --user is-enabled claude-sessions.service     # enabled
loginctl show-user ubuntu | grep Linger                 # Linger=yes
sudo reboot                                             # then: tmux ls  (cue, personal-web, infra)
```

## step-ca SSH cert renew-loop (M76)

So the agent SSHes to the homelab with a short-lived **step-ca cert** instead of the
standing `id_ed25519_homelab` key:
- `step-ssh-renew.sh` — mints a 13h user cert (principals `ubuntu`,`root`) to
  `~/.ssh/id_homelab_cert` via the headless JWK provisioner (jwk_password from SOPS).
- `step-ssh-renew.{service,timer}` — user units; the timer renews every 6h.
- `devbox.yml` writes a **cert-only** `~/.ssh/config` (`id_homelab_cert` is the sole
  `IdentityFile` for homelab hosts).

> **M76 cutover DONE (2026-06-26):** the static `id_ed25519_homelab` key is no longer
> deployed to the devbox and the running fleet **rejects** it (removed from
> `authorized_keys`, see `playbooks/step-ca-remove-static-key.yml`). The devbox SSHes
> cert-only; the renew-loop is the only credential. **Break-glass = PVE console + IPMI
> 10.10.200.21** (if the cert expires with step-ca down, mint manually or use the SOPS
> `automation_ssh_private_key` after re-adding it — both require step-ca/console access).

Install on devbox (one-time):
```bash
ln -sf ~/code/infra/infra/devbox/step-ssh-renew.service ~/.config/systemd/user/step-ssh-renew.service
ln -sf ~/code/infra/infra/devbox/step-ssh-renew.timer   ~/.config/systemd/user/step-ssh-renew.timer
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable --now step-ssh-renew.timer
~/code/infra/infra/devbox/step-ssh-renew.sh             # mint the first cert now
```
Verify: `ssh -v 10.10.201.53 2>&1 | grep -E 'Offering|Authenticated'` → offers
`id_homelab_cert ECDSA-CERT`, `Authenticated … using "publickey"`.
**Reboot test PASSED 2026-06-18:** all three sessions auto-resumed ~8s after boot, each
in the correct repo cwd. ⚠️ The scripts **must stay executable in git** (`0755`) — they
were once committed `0644` and only ran from a hand-`chmod`'d live copy, a latent
`ExecStart` failure a `git restore` would expose (fixed in `4b49e54`).

## TODO
- Codify the live-but-undocumented bits into `infra/ansible/playbooks/devbox.yml`:
  `kubectl` (v1.36.2) install + kubeconfig, and **this** `claude-sessions` systemd unit +
  linger. (devbox.yml currently ships the superseded single-session `claude-dev` launcher.)
- Copy the user's `~/.claude/.../memory/` files mini → devbox (not in git, didn't migrate).
- Migrate the cilium-audit `/loop` here as a systemd timer (see memory:
  project_devbox_cilium_audit_job).

## Weekly doc/IaC drift audit (`doc-drift-audit.timer`)

A live-anchored doc/IaC drift audit runs **weekly** on the devbox (it needs `kubectl` +
UDM-API + on-host `ip route` access a cloud-scheduled run can't reach). Headless `claude`
compares docs + IaC against LIVE state, **auto-fixes high-confidence DOC drift** (commit +
push), and posts a summary (auto-changes + manual-review items) to the `doc-drift` GitHub
issue. **IaC drift is reported, never auto-applied.** Files: `doc-drift-audit-prompt.md`
(prompt + hard safety rules), `doc-drift-audit.sh` (runner → `~/.local/state/doc-drift-audit/`
logs), `doc-drift-audit.{service,timer}`.

**Email every run (clean or drift).** Besides the GitHub issue, the runner emails the summary
to the operator (`EMAIL_TO` in `service-status-report/email.env`) on every run. The devbox has
no in-cluster IRSA, so it sends over **SES SMTP** — `doc-drift-audit.sh` decrypts the SES SMTP
creds from `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml` (it holds the age
key) and calls `send-audit-email.py` (pure-stdlib `smtplib`, From `service-status@wind.etherport.net`,
a verified SES sender). The audit writes `last-summary.md` + `last-status` (`clean`/`drift`) for
the mailer; if it doesn't, the runner emails a log-tail fallback so a run never goes silent. A
send failure never fails the audit (the GitHub issue stays the system of record).

**Approve buttons (deep-link, #40).** The email is multipart (plain + HTML, rendered by
`send-audit-email.py`'s small stdlib markdown→HTML). For each "Needs manual review" item whose
fix is an **apply workflow**, the audit appends a `[Review & apply →](…/actions/workflows/<file>.yml)`
link that the mailer renders as a green button → it opens that workflow's GitHub **Run workflow**
page (your GitHub login gates the dispatch; you click "Run workflow" to confirm). Deliberately NOT
a one-click HMAC receiver (no new public endpoint that could trigger infra applies) — proportionate
for a weekly audit. Pure-doc/ambiguous items get no button.

**Off-box failure/missed-run alert.** Email tells you a run *failed*; it can't tell you a run was
*missed* (devbox down / timer disabled → no email at all). So the runner also writes a node_exporter
textfile metric (`/var/lib/node_exporter/textfile_collector/doc_drift_audit.prom`:
`doc_drift_audit_last_rc` + `..._last_success_timestamp_seconds`, the success ts stamped only on
rc=0). `base.yml` enables `--collector.textfile` + creates that dir (devbox: `ubuntu`-owned so the
audit can write). Prometheus alerts (`doc-drift-audit.rules` in `02-external-alerts.yaml`):
`DocDriftAuditStale` (no success in >8d, **critical** → email), `DocDriftAuditNoMetrics`
(metric absent >9d, **critical**), `DocDriftAuditFailed` (last rc≠0, warning — the per-run error
email already covers it). ⚠️ The audit is a systemd **user** unit, so node_exporter's *systemd*
collector (system bus) can't see it — the textfile metric is the off-box signal, not unit-state.

**Permission scope (hardened after the 2026-06-30 adversarial review).** A prefix allowlist
**cannot** enforce "docs-only write / no exfil" for an unattended agent — shell redirection
(`echo x > file`, empirically proven), write-flags on allowed tools (`sort -o`, `curl -o`),
`git restore`, and `git push` all bypass path-scoping, and `sops -d`+`curl` is a secret-exfil pair.
So the model splits cleanly: **the agent gets NO `git`, NO `curl`/`wget`, NO `sops`** — only reads,
`Edit`/`Write` to `docs/**`/`README.md`/`CLAUDE.md`/`.audit-state/`, and the **read-only** helper
(`udm`/`gh-get` GETs). **The wrapper (`doc-drift-audit.sh`, trusted) owns ALL mutation:** it stages
**only doc paths** (flagging any non-doc write the agent attempted), **secret-scans** the staged
diff + the summary, then does the commit/push + issue-dispatch (`dispatch-issue` is gated behind a
wrapper-only `AUDIT_WRAPPER=1`) + email itself. So a prompt-injected agent **cannot reach the Flux
`main` branch or exfiltrate** — its only outbound is the helper's UDM/GitHub GETs and a
wrapper-scanned summary. The deny list also blocks `terraform`/`ansible`/`kubectl` mutations,
`rm`/`mv`/`tee`/`sed -i`, and **Reads of plaintext-secret paths** (`~/.config/sops`, `~/.ssh`,
`~/.aws`, `~/.claude`, `*.sops.yaml`). Residual: the agent can *read* a secret into context (no read
tool is fully path-scopeable) but has no un-scanned channel to emit it. Empirically validated:
allowed reads run; `git`/`curl`/`sops`/`kubectl delete`/`terraform` are all blocked.

⚠️ **This is an UNATTENDED agent that commits to `main`**, so it is **NOT auto-enabled** — enable it deliberately:
```bash
ln -sf "$PWD/infra/devbox/doc-drift-audit.service" ~/.config/systemd/user/
ln -sf "$PWD/infra/devbox/doc-drift-audit.timer"   ~/.config/systemd/user/
loginctl enable-linger ubuntu          # if not already
systemctl --user daemon-reload
systemctl --user enable --now doc-drift-audit.timer
systemctl --user list-timers doc-drift-audit.timer   # confirm next run
# Validate once before trusting the schedule:
systemctl --user start doc-drift-audit.service && tail -f ~/.local/state/doc-drift-audit/*.log
```
The safety rails are BOTH the scoped permission policy above (`doc-drift-audit-permissions.json`,
hard-enforced) AND the prompt's soft rules ("if unsure, report don't edit"). The policy is the
durable guarantee; the prompt guides good behavior within it.
