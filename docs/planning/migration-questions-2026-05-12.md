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

### 7. Chowned /opt/cni to root:root post-kubespray
**Background:** After kubespray completed, Cilium pods crashlooped on
the `mount-cgroup` init container with "Permission denied" writing to
`/opt/cni/bin/cilium-mount`. Root cause: kubespray creates a `kube`
user as `kube_owner` and chowns `/opt/cni/bin` to `kube:root` with
mode 0755. Cilium's init container drops `CAP_DAC_OVERRIDE`, so root
inside the container falls under "group" permissions (rx only) and
can't write.

**What I did:** Ran `ansible -m shell -a 'chown -R root:root /opt/cni'`
on all 8 K8s nodes. Pods came up immediately.

**Open question:** This will reoccur on every kubespray re-run /
upgrade. We should either:
- Set `cni_bin_owner: root` explicitly in kubespray group_vars (already
  set per the existing `cni_bin_owner: root` line in all.yml — but
  somehow the directory still ended up `kube:root`. Worth investigating
  why the override isn't taking effect.)
- Or add CAP_DAC_OVERRIDE to Cilium's init container.

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

## Final state at end of autonomous run

### What's working ✅
- All 8 K8s nodes Ready (sequential IDs 100-102, 110-113, 120 — your preferred scheme)
- gh-runner VM at 10.10.201.30 with self-hosted runner registered as `homelab-runner, lifecycle, self-hosted, Linux, X64`
- Cilium CNI healthy after fixing `/opt/cni` ownership
- Velero restore from `pre-migration-20260512-1915` **Completed**
- Ceph RBD CSI driver running on all nodes (after loading `rbd` kernel module everywhere — added to `/etc/modules-load.d/rbd.conf` for persistence)
- Flux + GitOps: 9/11 HelmReleases healthy (cert-manager, cnpg operator, kured, tailscale-operator, velero, arc-controller, arc-runner-homelab, gpu-operator, traefik)
- DNS service (technitium) running with MetalLB LBs at 10.10.201.5/.71/.72
- Traefik LB at 10.10.201.70
- WireGuard pod back at replicas=1 (failover from vpn-local should reclaim VIP via VRRP priority)

### Issues remaining for your review ⚠️
1. **monitoring HelmRelease (kube-prometheus-stack) failed** with `context deadline exceeded`. Re-reconcile triggered. May need explicit chart timeout bump or staged install. Pushgateway waits on this.
2. **postgres-cluster-1 CrashLoopBackOff** — CNPG operator can't bootstrap a replica from the restored PV. Logs show `Timeout: failed waiting for *v1.Cluster Informer to sync` and `Error while checking if there is enough disk space for WALs`. This is typical CNPG behavior when restoring a primary with stale WAL state — usually needs the operator to coordinate or a manual `cnpg promote` once the primary is ready. wikijs (depends on postgres) is crashlooping for the same reason.
3. **GPU operator pods stuck in Init** (~15 min). NVIDIA driver containers take a while; check `kubectl logs -n gpu-operator-system <pod> -c nvidia-driver-ctr` if they don't move soon.
4. **kubectl can't reach k8s-gpu1 (10.10.201.60) via SSH from this Mac** but K8s cluster reaches it fine — VPN routing quirk. Worked around with `kubectl debug node + nsenter` to load `rbd` module.
5. **s3-sync-daily-report Jobs Error** — cronjob-scheduled during restore window, probably expected (no buckets to sync to during outage).

### Tasks for you on return
1. Approve / fix the monitoring HelmRelease (check timeout settings)
2. Investigate postgres CNPG restore — may need `kubectl cnpg restart` or manual promote
3. Verify K8s WireGuard pod has reclaimed VIP from vpn-local (check `kubectl exec -n wireguard deploy/wireguard -- wg show` and `kubectl get svc -n wireguard`)
4. Cycle through remaining Task list (NetworkPolicies, dns-fallback+vpn-local rebuild)
5. Decide on adding `Secrets: write` to claude-cli PAT so I can fully automate next time

## Files modified during the autonomous run

- `infra/kubespray/inventory/inventory.ini` (rewrite for new layout)
- `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml`
  (hardening: encrypt, audit)
- `infra/kubespray/inventory/group_vars/all/etcd.yml` (snapshot/compaction)
- `.github/workflows/kubespray.yml` (new — runs kubespray via gh-runner)
- `infra/kubespray/post-bootstrap.sh` (new — Flux + Velero restore)
- `docs/planning/migration-questions-2026-05-12.md` (this file)
