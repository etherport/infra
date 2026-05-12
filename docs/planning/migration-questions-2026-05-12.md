# Migration Questions / Decisions Made Autonomously — 2026-05-12

Context: User stepped away mid-migration with instructions to drive to
completion. This file logs decisions I made without being able to ask,
plus open questions for review on return.

## Decisions made autonomously

### 1. Used both inventory locations for kubespray hardening
**Background:** Earlier hardening commit edited
`infra/ansible/inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml`,
but kubespray actually reads from
`infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml`. The
ansible inventory is only consumed by the homelab ansible playbooks
(proxmox.yml etc.), not kubespray.

**What I did:** Applied the same hardening (encrypt_secret_data,
audit logging, etcd snapshots) to the kubespray-managed group_vars.
Left the ansible-managed ones as-is — they're idle but harmless.

**Open question:** Do we want to consolidate the two inventories? Have
one source of truth, with kubespray symlinking or extending it? Cleaner
long-term.

### 2. Updated kubespray inventory.ini to new cluster shape
**Background:** `infra/kubespray/inventory/inventory.ini` had stale
content from the old single-CP cluster (1 CP, 3 workers, ansible_user
= graham at .50-.53 + .60).

**What I did:** Rewrote to 3 CPs + 4 workers + 1 GPU at canonical IPs
.50-.56 + .60, ansible_user = ubuntu (cloud-init default), with
StrictHostKeyChecking=accept-new so first ansible run doesn't fail on
unknown hosts.

### 3. Built kubespray.yml workflow on the new gh-runner
**What I did:** Created `.github/workflows/kubespray.yml` running on
the new lifecycle-tagged self-hosted runner. Steps:
- Install runner prereqs (python3-venv, build tools)
- Wipe any stale venv from prior failed runs
- Run ./setup.sh
- Run ./kubespray.sh <playbook>

**Open question:** This deploys via the gh-runner inside the homelab.
Should we also add a fallback path that can run from a different
runner if gh-runner is down (chicken-and-egg if gh-runner itself
breaks)?

### 4. Won't add new GH secrets (no PAT permission)
**Background:** `claude-cli` PAT lacks `Secrets: write`. We added
`Administration: write` for runner registration but didn't add Secrets.

**What I did:** I extracted the Flux deploy private key locally to
`/tmp/flux-deploy-key` and will run Flux bootstrap from this Mac
(post-bootstrap.sh) instead of via a workflow.

**Open question:** Want to add `Secrets: write` to claude-cli PAT
so future bootstrap can be fully automated via GH Actions? Trade-off
is more PAT exposure if it's compromised.

### 5. Deferred dns-fallback + vpn-local recreation (Task #4)
**Background:** Standalone-vms TF plan also wants to destroy and
recreate dns-fallback (1001) and vpn-local (1002) because of the
clone source change (9000 → 9001). But vpn-local is actively serving
your VPN session.

**What I did:** Used `terraform apply -target` to only create the
new `gh-runner` VM. The two existing services stay running. Tracked
as Task #4 in the task list.

### 6. Built post-bootstrap.sh (Flux + Velero restore)
**What I did:** Written at `infra/kubespray/post-bootstrap.sh`.
Fetches kubeconfig via SSH, creates Flux + sops-age secrets, applies
Flux components, waits for reconciliation, triggers Velero restore
from `pre-migration-20260512-1915`, scales wireguard back to 1.

**Open question:** Should this become a workflow on the gh-runner
once we have `Secrets: write` PAT permission? Long-term yes, but for
this bootstrap it runs locally.

## Open architectural questions for your review

1. **Two inventories (ansible vs kubespray)** — consolidate?
2. **Secrets management for Flux deploy key + SOPS age** — currently
   GH secrets (SOPS_AGE_KEY) + manual handling (FLUX deploy key).
   Want both in GH secrets and a single workflow pulling them?
3. **Why does kubespray inventory have its own group_vars?** Could
   point at the ansible inventory's group_vars via symlink and avoid
   duplication.
4. **What's the canonical kubeconfig location?** Currently saved to
   `/tmp/wind-kubeconfig` on this Mac. Should it land in
   `~/.kube/config` (replacing the old one)? Or be committed/saved to
   1P for future agent runs?
5. **Standalone runner labels** — currently `homelab-runner, lifecycle,
   self-hosted, Linux, X64`. Should some workflows use ONLY `lifecycle`
   to skip the runner-in-K8s? Workflows that touch K8s cluster
   lifecycle specifically.

## Files modified during the autonomous run

- `infra/kubespray/inventory/inventory.ini` (rewrite for new layout)
- `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml`
  (hardening: encrypt, audit)
- `infra/kubespray/inventory/group_vars/all/etcd.yml` (snapshot/compaction)
- `.github/workflows/kubespray.yml` (new — runs kubespray via gh-runner)
- `infra/kubespray/post-bootstrap.sh` (new — Flux + Velero restore)
- `docs/planning/migration-questions-2026-05-12.md` (this file)
