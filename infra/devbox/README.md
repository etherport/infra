# devbox — Claude Code dev host (Linux)

devbox (`10.10.201.45`, ansible `playbooks/devbox.yml`, always-on Ubuntu VM, no
FileVault gate) hosts the Claude Code **dev sessions** (cue, personal-web, and
eventually infra), migrated off the Mac mini so they survive mini reboots and are
remote-controllable from claude.ai. The mini keeps the macOS-only work (Photos/iCloud).

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
sudo reboot                                             # then: tmux ls  (cue, personal-web)
```

## TODO
- Add `infra` to `SESSIONS=(...)` once that thread is migrated off the mini.
- Codify all of the above (kubectl install, ssh-config, authorized_keys, this unit)
  into `infra/ansible/playbooks/devbox.yml` for full reproducibility.
- Migrate the cilium-audit `/loop` here as a systemd timer (see memory:
  project_devbox_cilium_audit_job).
