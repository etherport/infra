# Secrets rotation runbook

How to rotate the SOPS **age key** (routine + post-compromise) and the downstream
secrets it protects. Addresses outstanding-work **H33**.

> **Inventory of every credential** (what/where/consumers/blast-radius) →
> [`../reference/credential-inventory.md`](../reference/credential-inventory.md).
> This runbook covers *how to rotate*; that doc is the *map*.

## Blast radius — read first

One age recipient (`age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g`)
decrypts **every** `*.sops.yaml` (all 5 `creation_rules` in `.sops.yaml` use it). Its
**private** half is replicated to **four** places — these are what an attacker would
need, and what rotation must cover:

| Holder | Path / location | Used for |
|---|---|---|
| Mac mini (ops host) | `~/.config/sops/age/keys.txt` (un-passphrased) | headless `sops -d`, ansible, render scripts |
| devbox (dev-session host) | `~/.config/sops/age/keys.txt` (deployed by `devbox.yml`) | headless `sops -d` in Claude Code dev sessions |
| GitHub Actions | repo secret `SOPS_AGE_KEY` | CI workflows that decrypt (terraform-drift, post-bootstrap, ansible-vm-fleet) |
| Flux (in-cluster) | secret `sops-age` in `flux-system` | decrypts `platform/kubernetes/**/*.sops.yaml` at reconcile |
| **offline backup** ✅ (2026-06-15) | `age1phcm…3466` — 1Password "Homelab SOPS Age Key (BACKUP)" + paper in a safe — NEVER on the mini/CI/Flux | break-glass recovery + lockout-free re-key (added via H33a, below) |

Downstream secrets fall into **two management classes** (rotation handles them differently):
- **1P-managed (synced):** listed in `infra/ansible/playbooks/secrets/homelab-ops.manifest.yaml`, rendered by `scripts/sync-secrets.py` → `homelab-ops.sops.yaml`. Covers AWS (tf), UDM creds, Cloudflare token, Twilio, the automation SSH key.
- **Hand-edited standalone SOPS files (NOT in any manifest):** rotated with `sops <file>` directly — Anthropic key, SMTP, Ceph (`ceph-k8s-secret.sops.yaml`, `ceph.sops.yaml`), WireGuard keys (`platform/wireguard/**`), approval-hmac, advisor-ssh-key, CNPG/barman creds, grafana-admin.

---

## H33a — add an offline backup recipient (do once, removes lockout risk)

> ✅ **DONE 2026-06-15.** Backup recipient `age1phcm…3466` ("Homelab SOPS Age Key
> (BACKUP)", offline only) added to all 5 `creation_rules` + 14 nested `.sops.yaml`
> and `sops updatekeys`'d across all 39 secret files (verified: every file carries
> both recipients; all 39 decrypt with the primary). Steps below are the reference
> if you ever re-do it (e.g. for a 3rd recipient). The keypair was generated on the
> laptop; the private half never touched the mini/CI/Flux.

The single key today has no backup: lose/rotate it wrong and the whole estate is
undecryptable. Add a second recipient held **offline** so you can always recover and
re-key without lockout. The add-then-`updatekeys` flow never has a window where you
can't decrypt (the primary stays a recipient throughout).

```bash
# 1. generate the backup keypair ON THE LAPTOP (not the mini)
umask 077; age-keygen -o /tmp/sops-backup-age.txt
grep 'public key' /tmp/sops-backup-age.txt     # -> age1backup…  (the recipient)

# 2. STORE THE PRIVATE HALF OFFLINE: 1Password item "Homelab SOPS Age Key (BACKUP)"
#    + printed in the safe. Do NOT add it to the manifest, the mini, CI, or Flux.
rm -P /tmp/sops-backup-age.txt                  # scrub after storing

# 3. add age1backup… to ALL 5 creation_rules in .sops.yaml (comma-joined list) and
#    to the ~7 nested .sops.yaml config files (grep for the primary recipient):
grep -rl 'age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g' --include='.sops.yaml' .

# 4. re-encrypt every secret for the new recipient set (primary still present = no lockout):
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
find . -name '*.sops.yaml' -not -name '.sops.yaml' -not -path './.git/*' -exec sops updatekeys -y {} \;
git add -A && git commit -m "secrets: add offline backup age recipient + re-key"
```
No Flux/CI change needed — they still decrypt with the primary.

---

## Routine age-key rotation (periodic hygiene)

Two-phase: **add the new key everywhere → verify → remove the old.** Never remove the
old recipient before all four holders carry the new private key.

```bash
# 1. new primary (laptop)
age-keygen -o /tmp/new-primary.txt
# 2. add the NEW public key alongside the old in all creation_rules (.sops.yaml + nested)
# 3. re-key (old still present → no lockout):
find . -name '*.sops.yaml' -not -name '.sops.yaml' -not -path './.git/*' -exec sops updatekeys -y {} \;
git commit -am "secrets: rotate age key (phase 1: add new recipient)"
# 4. distribute the NEW private key to the four holders:
#    mini:    write ~/.config/sops/age/keys.txt (chmod 600)
#    devbox:  write ~/.config/sops/age/keys.txt (chmod 600) — or re-run devbox.yml
#    GitHub:  gh secret set SOPS_AGE_KEY < /tmp/new-primary.txt
#    cluster: kubectl create secret generic sops-age -n flux-system \
#               --from-file=age.agekey=/tmp/new-primary.txt --dry-run=client -o yaml | kubectl apply -f -
#             kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
#             kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
# 5. verify all three decrypt (a CI run, a Flux reconcile, a sops -d on the mini)
# 6. remove the OLD public key from .sops.yaml + nested, updatekeys again, commit.
#    Update the recipient string in docs/setup/headless-ops-host.md + SOPS-SETUP.md.
rm -P /tmp/new-primary.txt
```

---

## Incident: the mini is compromised → rotate everything

The mini holds the un-passphrased age key **plus** the homelab SSH key, the kubeconfig
(cluster-admin), and (once configured) AWS creds. Assume **all of it** leaked. Rotate
the access-gating key first, then everything it could have decrypted.

**0. Contain.**
- Power off / isolate the mini.
- Remove `10.10.202.101` from the `trusted-admin-clients` group in `udm-firewall.yml` and re-apply **from the laptop**; revoke the mini's Tailscale node. NB fleet SSH is **cert-only** (M76) — a leaked static homelab key no longer opens any running host, but the mini's SOPS bundle copy exposes the **bootstrap** `automation_ssh_private_key` (cloud-init seed for NEW hosts): rotate it in the bundle + the cloud-init TF vars, and pull any residual break-glass pubkeys from `root@pve`'s `authorized_keys`.

**1. Rotate the age key** (routine procedure above) — generate a fresh primary, `updatekeys`, redistribute to GitHub + Flux. **Do NOT** put it back on the compromised mini.

**2. Force-rotate the GitHub `SOPS_AGE_KEY` + Flux `sops-age` secret** (the leaked key still decrypts old git ciphertext, so step 3 is mandatory).

**3. Rotate every downstream secret the old key exposed** — broadest-access first:
1. **AWS keys** (tf backend, M75-orphaned dedicated keys, SES SMTP) — deactivate old IAM keys in console, create new, update 1P. NB in-cluster AWS workloads (velero, s3-sync, CNPG barman, cloudwatch-to-loki, ai-advisor) are **IRSA-based (M75)** — they assume short-lived creds via `AssumeRoleWithWebIdentity`, hold no static keys, and need no rotation here; only standing IAM access keys do.
2. **kubeconfig / cluster-admin** — if `admin.conf` leaked, rotate the kube admin cert (cross-ref cert rotation; out of this runbook's scope).
3. **UDM creds** (1P items `di4fnt6r…`, `6e3ceofu…`, `vohajmkz…`) — change in UniFi, update 1P.
4. **WireGuard keys** — regenerate server+client keypairs (`platform/wireguard/**`, `platform/kubernetes/wireguard/01-secrets.sops.yaml`); update both tunnel ends.
5. **Anthropic key** — rotate in console → `anthropic-api-key.sops.yaml`.
6. **SMTP** (`platform/kubernetes/monitoring/alertmanager-secret.sops.yaml`); **Ceph** (`ceph-k8s-secret.sops.yaml`, `ceph.sops.yaml`); **Cloudflare token** (1P `k4tmkn7t…`); **Twilio**, **approval-hmac**, **advisor-ssh-key**, **CNPG/barman**, **grafana-admin** — rotate each.

**4. Re-sync the 1P-managed half** (laptop, 1P unlocked):
```bash
python3 scripts/sync-secrets.py
git commit -am "secrets: post-incident rotation (1P-managed)"
```
**5. Re-encrypt the hand-edited standalone files** — `sops <file>` each (paste new value, save).
**6. Reconcile/redeploy:** `kubectl annotate --overwrite -n flux-system kustomization/<name> reconcile.fluxcd.io/requestedAt="$(date +%s)"` (annotate `gitrepository/flux-system` too to pull the source); re-apply WireGuard via ansible; re-apply `udm-firewall.yml` from the laptop.
**7. Re-provision a clean ops host** from `docs/setup/headless-ops-host.md` with the NEW primary key only.

---

## Hardening follow-ups
- FileVault on the mini (the age key is un-passphrased on disk).
- Consider a per-domain recipient split (separate WG key + CI key) so one holder's
  compromise doesn't expose the whole estate — tradeoffs in `outstanding-work.md` H33.
- Grant the audit principal `iam:GetAccessKeyLastUsed` so key-age sweeps work.
