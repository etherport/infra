# 1Password CLI Integration → merged into `SOPS-SETUP.md`

> **This page was merged into [`SOPS-SETUP.md`](SOPS-SETUP.md) (M68, 2026-06-17).**
> See its **"1Password CLI (`op`) quick-reference"** section for the current,
> de-staled guidance.

The old content here was built around the **deleted** "AWS Key (Route 53 Updater)"
1Password item and the decommissioned Route53 DDNS path (Route53 retired 2026-05-27;
DDNS moved to Cloudflare). It also incorrectly implied an agent could run `op` — in
this project `op` only authorizes the **operator's interactive/VNC session**, never
headless/agent bash. Both are corrected in `SOPS-SETUP.md`.

**Canonical secrets references:**
- [`SOPS-SETUP.md`](SOPS-SETUP.md) — SOPS + age + the `op` quick-reference (this file's successor).
- `scripts/sync-secrets.py` (+ its manifest) — the canonical `op` → SOPS pipeline.
- [`../../runbooks/secrets-rotation.md`](../../runbooks/secrets-rotation.md) — rotation procedure.
