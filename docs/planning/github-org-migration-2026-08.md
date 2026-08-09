# GitHub Org Migration — `sparked-diamond` (user) → `etherport` (org)

**Goal:** consolidate the 6 repos under a GitHub **Organization** named `etherport`
(brand = `etherport.net`). The personal user account `sparked-diamond` **stays** — only
the repos move. Created 2026-08-07 (`etherport`, org id 314430121).

**Repos moving (6):** `infra`, `cue`, `cue-certs`, `cairn`, `gs-brand`, `personal-web`
(all private).

> **Status legend:** ☐ pending · ▶ in progress · ✅ done. Each step is tagged
> **[OWNER]** (you, in the GitHub UI) or **[AGENT]** (me, on the devbox/CI).

---

## 0. What is NOT changing — do not touch these

A blanket find-replace of `sparked-diamond` would **break** these, because your *user*
identity is unchanged:

- **Tailscale ACL** — `src: "sparked-diamond@github"` in `infra/tailscale/policy.hujson`
  and the `sparked-diamond.github` tailnet. The tailnet grants by GitHub **user**; your
  user keeps its name. Touching this breaks remote access. **LEAVE.**
- **`docs/planning/archive/**` and past `session-log.md` entries** — historical record of
  what was true then. **LEAVE.**
- **git commit author identity** — unaffected by any of this.

---

## 1. What changes (and why each is risky)

| # | Thing | Where | Risk if wrong |
|---|---|---|---|
| A | **GHCR image paths** — the `sparked-diamond` namespace → the `etherport` namespace (`aws-s3-sync`, `cloudflare-ddns`, `cloudwatch-to-loki`, `ansible-runner`, `cue`) | 4 in-repo image workflows + `cue` repo's own workflow + ~all `platform/**` manifests + Renovate | **Outage** — Flux can't pull → pods won't start on restart |
| B | **OIDC → AWS trust** `repo:sparked-diamond/infra` / `…/personal-web` | `infra/terraform/aws/github-oidc/main.tf` (roles `gh-actions-terraform`, `gh-actions-personal-web`) | **Silent CI break** — CI loses AWS on next run |
| C | **Self-hosted runner** registered to `sparked-diamond/infra` (unit `actions.runner.sparked-diamond-infra.*`) | `infra/ansible/playbooks/gh-runner.yml` (`repo_url`, service name) + **runtime re-registration** | **CI has no runner** until re-registered |
| D | **Flux source URL** + git remotes | `clusters/wind/flux-system/gotk-sync.yaml`, image-automation, `helm-releases/github-actions-runner.yaml`, devbox/mini `.git/config` | Flux stops reconciling (git redirect softens this) |
| E | **Mirror backup** — enumerates the *user* (`/user/repos`); repos become *org*-owned; its user-scoped PAT won't see org repos | `platform/kubernetes/backups/github-mirror/` | Mirror silently backs up 0 repos |
| F | **Image-build workflows** use `/users/` package API + had PATCH-404 workarounds | the 4 image workflows | Package-visibility step 404s (an org actually *fixes* this) |
| G | Active docs (README, CLAUDE.md, credential-inventory, current runbooks) | ~62 refs | Stale docs |

---

## 2. Two deadlock hazards — designed around

- **OIDC deadlock:** transferring `infra` makes CI lose AWS, but the fix (a TF apply)
  *runs on CI*. **Break it with dual-trust:** the IAM trust `sub` uses `StringLike` on a
  **list**, so we add `repo:etherport/infra:*` alongside the existing `repo:sparked-diamond/infra:*`
  **before** the transfer (applied while CI still works). After cutover, drop the old path.
- **Runner deadlock:** nothing CI-based runs until the runner re-registers to the new repo.
  So runner re-registration is the **first** post-transfer action, before we lean on CI.

---

## 3. Phase 0 — pre-cutover prep (AGENT, non-breaking, no downtime)

Done while everything still works. **Nothing here breaks the running system.**

- ☐ **[AGENT] P0.1 — Branch `chore/github-org-etherport`** (staged, NOT merged) with all of:
  A (GHCR paths), B (OIDC dual-trust — see P0.2), D (Flux/git URLs), E (mirror → org
  enumeration + `GH_OWNER=etherport`), C-file (runner `repo_url`/unit name), F (image
  workflow user→org), G (active docs). Tailscale + archives untouched.
- ☐ **[AGENT] P0.2 — Apply dual-trust OIDC** (additive): add `repo:etherport/infra:*`
  (+ `…/personal-web`) to the trust `values` lists, dispatch the OIDC TF **against the
  branch** so AWS trusts BOTH old and new subs. Verify the live IAM role trust policy
  lists both. *This is the one Phase-0 change that hits prod, and it is purely additive.*
- ☐ **[AGENT] P0.3 — Validate** `kubectl kustomize clusters/wind` builds on the branch;
  `sh -n` the mirror script; confirm no Tailscale/archive refs were swept.
- ☐ **[OWNER] P0.4 — (optional, can wait) create the GitHub App** on the `etherport` org
  (we fold the PAT→App migration into Phase 2). See [App plan](#5-phase-2--app--cleanup).

**➡️ When Phase 0 is done, I ping you to start Phase 1. Until then: nothing for you to do.**

---

## 4. Phase 1 — cutover (short maintenance window)

> Expect a few minutes where Flux/CI are re-pointing. Running pods keep running
> (already-pulled images); the exposure is new pulls / CI runs during the window.

- ☐ **[OWNER] 1.1 — Transfer the 5 non-`infra` repos** first: for each of `cue`,
  `cue-certs`, `cairn`, `gs-brand`, `personal-web` → repo **Settings → Danger Zone →
  Transfer ownership → new owner `etherport`**. (Their GHCR packages move with them.)
- ☐ **[OWNER] 1.2 — Transfer `infra` LAST** (same steps). This is the moment Flux/CI/OIDC
  re-point.
- ☐ **[OWNER] 1.3 — Runner token:** on `etherport/infra` → **Settings → Actions → Runners →
  New self-hosted runner** → copy the **registration token** → hand it to me (drop on the
  devbox like the PAT, or paste — it's short-lived, ~1h).
- ☐ **[AGENT] 1.4 — Re-register the runner** to `etherport/infra` (`config.sh remove` old →
  `config.sh --url https://github.com/etherport/infra --token …` → re-enable the systemd
  unit, now `actions.runner.etherport-infra.*`). Confirm the runner shows **online** in the
  org repo.
- ☐ **[AGENT] 1.5 — Merge the branch to `main`** (GHCR paths, Flux URL, mirror→org, docs).
- ☐ **[AGENT] 1.6 — Update live git remotes** on devbox + mini
  (`git remote set-url origin git@github.com:etherport/infra.git`).
- ☐ **[AGENT] 1.7 — Reconcile Flux**, verify it pulls `ghcr.io/etherport/*` and reconciles
  green; verify no pod is stuck ImagePullBackOff.

---

## 5. Phase 2 — App + cleanup (AGENT, with 2 OWNER clicks)

- ☐ **[OWNER] 2.1 — Install the GitHub App** on `etherport` (all repos; Contents:read +
  Metadata:read + Actions:read/write). Give me the App ID + Installation ID + private-key
  PEM (drop on devbox; I encrypt + shred).
- ☐ **[AGENT] 2.2 — Point the mirror + dispatch at the App** (1h installation tokens; see
  the separate GitHub-App plan). Retire the user read-only PAT + `github_dispatch_pat`.
- ☐ **[AGENT] 2.3 — Drop the old OIDC trust path** (`repo:sparked-diamond/infra`), apply,
  verify a CI run still gets AWS.
- ☐ **[AGENT] 2.4 — Verify GHCR packages** are all under `ghcr.io/etherport/*`; trigger the
  image-build workflows once to confirm they push to the new namespace.
- ☐ **[AGENT] 2.5 — Docs:** update `credential-inventory.md`, CLAUDE.md, tracker,
  session-log; archive this runbook.

---

## 6. Verification checklist (green = done)

- ☐ Flux `kustomization/flux-system` Ready=True on a post-merge revision
- ☐ No pod ImagePullBackOff on `ghcr.io/etherport/*`
- ☐ One CI workflow run on `etherport/infra` succeeds (proves runner + OIDC→AWS)
- ☐ `github-repo-mirror` job discovers **6** repos and bundles them (org enumeration)
- ☐ Tailscale remote access still works (ACL untouched)
- ☐ Old `sparked-diamond/infra` OIDC path removed; CI still gets AWS

---

## 7. Rollback

Within GitHub's redirect grace period a transfer is reversible (org → user, per repo).
Because the **OIDC dual-trust keeps the old path valid** throughout, and the sweep lives on
a branch until 1.5, the safe rollback at any point before merge is: transfer repos back to
`sparked-diamond`, do nothing else. After merge, roll back = `git revert` the sweep +
transfer back + re-register the runner to the old repo.
