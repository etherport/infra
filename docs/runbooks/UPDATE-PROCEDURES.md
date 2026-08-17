# System Update Procedures

Single source of truth for all infrastructure update procedures — what updates
automatically, what needs a human, and on what cadence. (The former
`dependency-update-cadence.md` was merged into this doc 2026-07-01.)

---

## Quick Reference: What Updates Automatically?

```
┌──────────────────────────────────────────────────────────────────┐
│                    FULLY AUTOMATIC                               │
│                    (no action needed)                            │
├──────────────────────────────────────────────────────────────────┤
│  Container Images (14)    Flux scans hourly, commits to git      │
│  K8s Node OS Patches      unattended-upgrades, security-only     │
│                           (M116)                                 │
│  K8s Node Reboots         Kured coordinates 2-6am Pacific        │
│  Standalone VM OS         unattended-upgrades + auto-reboot      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                    SEMI-AUTOMATIC                                │
│                    (review & merge PRs)                          │
├──────────────────────────────────────────────────────────────────┤
│  Helm Charts (17, exact-  Renovate flux manager PRs (M122)       │
│    pinned HelmReleases)                                          │
│  K8s manifest images      Renovate kubernetes manager PRs        │
│  Terraform Providers      Renovate creates PRs on new releases   │
│  GitHub Actions           Renovate creates PRs on new releases   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                    MANUAL                                        │
│                    (run playbook/commands)                       │
├──────────────────────────────────────────────────────────────────┤
│  Proxmox Host OS          Ansible playbook (monthly)             │
│  Kubernetes Version       Kubespray (quarterly)                  │
│  GPU Drivers              GPU Operator Helm upgrade              │
└──────────────────────────────────────────────────────────────────┘
```

---

## Update Timeline

```
DAILY (Automatic - no action needed)
──────────────────────────────────────────────────────────────────
  Continuous    Container images scanned & updated (Flux)
  ~04:00        Security patches installed (unattended-upgrades)
  02:00-06:00   K8s node reboots if needed (Kured, one at a time)
  02:00         dns-fallback reboot window
  03:00         vpn-fallback reboot window
  03:30         vpn-aws (edge box) reboot window

WEEKLY (Review required)
──────────────────────────────────────────────────────────────────
  Monday AM     Review and merge Renovate PRs
                └── Helm charts, Terraform providers, GitHub Actions

MONTHLY (Manual)
──────────────────────────────────────────────────────────────────
  1st Weekend   Proxmox host updates
                └── Run: ansible-playbook playbooks/proxmox.yml
                Packer template rebuild (VM 9001) + Flux ImagePolicy check
                └── See §3.4 below

QUARTERLY (Manual - requires maintenance window)
──────────────────────────────────────────────────────────────────
  Scheduled     Kubernetes version upgrade (Kubespray)
  Weekend       └── See kubernetes-upgrade.md for full procedure
                Major-version Renovate PRs + shell-installed-binary sweep
                └── See §3.5 below

ANNUALLY
──────────────────────────────────────────────────────────────────
  Any time      Refresh renovate.json against latest preset coverage
                └── See §3.6 below
```

---

## Detailed Status Table

| Component | Count | Method | Frequency | Action |
|-----------|-------|--------|-----------|--------|
| Container Images | 14 | Flux ImageUpdateAutomation | Hourly scan | None |
| K8s Node OS | 8 nodes | unattended-upgrades (security-only, M116) | Daily | None |
| K8s Node Reboots | 8 nodes | Kured | 2-6am when needed | None |
| Standalone VM OS | 6 local PVE + 1 AWS | unattended-upgrades | Daily | None |
| Standalone VM Reboots | 3 staggered (others default) | Staggered cron | 02:00-03:30 | None |
| Helm Charts | 17 releases (exact-pinned) | Renovate flux-manager PRs (M122) | On release | Merge PR |
| K8s manifest images | `platform/kubernetes/**` | Renovate kubernetes-manager PRs (M122) | On release | Merge PR |
| Terraform Providers | ~10 sources | Renovate PRs | On release | Merge PR |
| GitHub Actions | varies | Renovate PRs | On release | Merge PR |
| Proxmox Host | 1 | Ansible | Monthly | Run playbook |
| Kubernetes Version | cluster | Kubespray | Quarterly | Run playbook |
| GPU Drivers | 1 node | GPU Operator | As needed | Helm upgrade |

---

## 1. Fully Automatic Updates

### 1.1 Container Images (Flux)

**Images tracked (14):**
- ollama, open-webui, technitium, wikijs, plex
- rclone, home-assistant, cue, cloudflared
- python:alpine, python:slim, busybox, blackbox-exporter, velero-plugin-aws

**How it works:**
1. Flux ImageRepository scans registries hourly
2. ImagePolicy selects latest version matching constraints
3. ImageUpdateAutomation commits tag update to git
4. Flux deploys the new version

**Monitor:**
```bash
kubectl get imagepolicy -n flux-system                 # Current versions
kubectl get imageupdateautomation -n flux-system       # Automation status
git log --oneline --author="Flux" -10                  # Recent auto-commits
```

**Rollback:**
```bash
git revert <commit-sha> && git push
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

---

### 1.2 Kubernetes Node OS

**Nodes (8):** k8s-cp1/cp2/cp3, k8s-w1/w2/w3/w4, k8s-gpu1

**How it works:**
1. `unattended-upgrades` installs security patches daily
2. Creates `/var/run/reboot-required` when reboot needed
3. Kured detects flag, schedules reboot during 2-6am Pacific
4. Kured cordons node, drains pods, reboots, waits for ready
5. Only one node reboots at a time

**Monitor:**
```bash
kubectl get ds kured -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=20

# Check if nodes need reboot
ansible k8s_cluster -i infra/ansible/inventory/wind/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"
```

---

### 1.3 Standalone VM OS

There are **7 local PVE standalone VMs** (1001 dns-fallback, 1002 vpn-fallback,
1003 gh-runner, 1004 asterisk-sbc, 1005 devbox, 1006 step-ca, 1007 home-radio) **+ 1 AWS VM**
(vpn-aws — the single `private-infra_edge` box running VPN + Tailscale + DNS since
M110). Only the 3 below have explicit staggered reboot windows; the other VMs
reboot on the default schedule.

**VMs with staggered reboot windows:**
| VM | IP | Purpose | Reboot Time |
|----|-----|---------|-------------|
| dns-fallback | 10.10.201.6 | Backup DNS | 02:00 |
| vpn-fallback | 10.10.201.15 | Local VPN | 03:00 |
| vpn-aws | 10.10.100.10 | AWS edge (VPN + DNS + Tailscale) | 03:30 |

**Monitor:**
```bash
ansible dns_servers,vpn_servers \
  -i infra/ansible/inventory/wind/inventory.ini \
  -i infra/ansible/inventory/aws/inventory.ini \
  -a "cat /var/run/reboot-required 2>/dev/null || echo 'No reboot needed'"
```

---

## 2. Semi-Automatic Updates (Renovate PRs)

**What Renovate tracks (M122, 2026-07-03):**
- Helm chart versions — the **`flux` manager** on `clusters/wind/helm-releases/**`.
  All 17 HelmReleases are **exact-pinned** to the deployed version (semver *ranges*
  were silently freezing majors — never reintroduce a range)
- Container images in raw manifests — the **`kubernetes` manager** on
  `platform/kubernetes/**`. Exclusions: `goauthentik/server` and
  `cloudnative-pg/postgresql` images (program-managed upgrades, not PR-bumped)
- Terraform provider versions
- GitHub Actions versions
- Major versions always arrive as **individual PRs** (never grouped)

**Workflow:**
1. Renovate scans repo continuously
2. Creates PR when update available
3. You review the PR (check release notes)
4. Merge PR
5. Flux/Terraform applies changes

**View open PRs:**
```bash
gh pr list --label renovate
# Or: https://github.com/etherport/infra/pulls
```

> The `gh` CLI is **not** installed on the devbox — triage from a host that has it
> (the mini or a laptop), or use the GitHub web UI. The devbox dispatches GitHub
> Actions via the M92 Actions PAT/API, not `gh`.

**Weekly triage rules (~15 min):**
- **Patch/minor on infra** (TF providers, GH Actions, Helm minors, container minors)
  → review the changelog link in the PR body, merge if no breaking notes. Flux/CI
  takes it from there.
- **Major on anything stateful** (Cilium, CNPG, cert-manager, Traefik, Flux,
  kubespray itself) → close with a comment, schedule for the next quarterly window.
  Don't auto-merge majors.
- **A PR open >2 weeks** → merge or close. Stale Renovate PRs accumulate merge
  conflicts and stop being useful.

**Current Helm releases tracked** (files in `clusters/wind/helm-releases/`; list
live with `kubectl get helmrelease -A` — note the live names differ in two spots:
`github-actions-runner.yaml` materializes as the `arc-controller` + `arc-runner-homelab`
HRs, and `tailscale-connector.yaml` is a Flux Kustomization, not a HelmRelease):
alloy, cert-manager, cnpg, github-actions-runner, gpu-operator, kured, kyverno,
loki, metallb, metrics-server, monitoring, pushgateway, tailscale-connector,
tailscale-operator, tetragon, traefik, velero.

---

## 3. Manual Updates

### 3.1 Proxmox Host (Monthly)

```bash
cd ~/code/infra/infra/ansible

# Dry-run
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml --check --diff

# Apply updates
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml

# If reboot required
ansible-playbook -i inventory/wind/ playbooks/proxmox.yml -e "allow_reboot=true"
```

**Pre-update:** Verify VM backups are current, schedule low-usage period.

---

### 3.2 Kubernetes Version (Quarterly)

**Full procedure:** See [kubernetes-upgrade.md](kubernetes-upgrade.md)

```bash
cd ~/code/infra/infra/kubespray

# Update Kubespray
git submodule update --remote kubespray
cd kubespray && git checkout v2.XX.X && cd ..

# Run upgrade via the wrapper (auto-runs pre-flight to restore the CNI dir owner —
# NEVER raw ansible-playbook cluster.yml/upgrade-cluster.yml; see cilium-cni-dir-owner)
# Runs FROM THE DEVBOX (venv ~/.kubespray-venv) in a DETACHED tmux; export
# KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert (wrapper default is the dead static key)
cd infra/kubespray && KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert ./kubespray.sh upgrade-cluster.yml

# Verify
kubectl get nodes
kubectl get pods -A | grep -v Running
```

**Pre-upgrade:** Backup etcd, review K8s changelog, ensure Velero backups current.

---

### 3.3 GPU Drivers

GPU Operator manages drivers. Update the operator to get new drivers:

```bash
# Check current version
kubectl exec -it -n gpu-operator-system \
  $(kubectl get pods -n gpu-operator-system -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}') \
  -- nvidia-smi

# Update operator
helm repo update
helm upgrade gpu-operator nvidia/gpu-operator \
  -n gpu-operator-system \
  -f platform/kubernetes/gpu-operator/values.yaml
```

---

### 3.4 Monthly — Packer template rebuild + Flux ImagePolicy check

**1. Rebuild VM 9001 to refresh the Ubuntu kernel + baked tools:**

```bash
cd infra/packer/ubuntu-cloud-init
packer build .
# Packer destroys + recreates VM 9001 on PVE. Subsequent standalone-vms
# applies will pick up the new template on next clone.
```

If a service VM is rebuilt this month anyway (e.g. you destroyed dns-fallback for
a fix), it picks up the new base. Otherwise the old VMs keep their old kernel
until you trigger a rebuild.

**2. Verify Flux image automation is actually firing for the Renovate-deny-listed
images** (`ollama`, `open-webui`, `technitium/dns-server`, `requarks/wiki`,
`plexinc/pms-docker`, `rclone/rclone`, `home-assistant`, `python`, `busybox`,
`etherport/*` — Flux owns these via `ImagePolicy` CRDs):

```bash
kubectl get imagepolicy -n flux-system
# Each policy should show a recent LATEST IMAGE. If LAST UPDATED is
# weeks/months old, the policy isn't matching new tags — check
# the regex against the registry tags page.

kubectl get imageupdateautomation -n flux-system
# Must be Ready=True. If not, Flux is finding new images but failing
# to commit the bumps to git.
```

If any policy is stale, treat that image as **manually maintained** for now:
check the registry, bump the tag in the Flux resource by hand, fix the
ImagePolicy regex in a follow-up.

---

### 3.5 Quarterly — the rest of the manual list

Beyond the K8s upgrade (§3.2) and Proxmox host (§3.1), the quarterly window covers:

**1. Ubuntu LTS check.** Currently 24.04. A new LTS lands every 2 years. When
ready, bump the cloud-image URL in `infra/packer/ubuntu-cloud-init/` and rebuild
VM 9001.

**2. Major-version PRs from Renovate.** Re-open the ones closed during weekly
triage. Plan + apply in this window with downtime budget.

**3. Shell-installed binaries** — the blind spot Renovate can't touch:
- `.NET runtime` in `infra/ansible/playbooks/technitium.yml` (channel `X.Y` —
  check [dotnet.microsoft.com/download](https://dotnet.microsoft.com/download))
- Any `curl ... | sh` install in Packer / Ansible
- Kubespray git ref (if pinned vs floating)

```bash
grep -rEn "dotnet-install\.sh|curl.*\|\s*(sh|bash)|wget.*\.tar\.gz" \
  infra/ansible infra/packer | grep -v "^Binary"
```

For each hit, check upstream for a newer version, bump in the playbook, document
the change in a comment.

---

### 3.6 Annually — refresh the Renovate preset

```bash
# 1. Skim Renovate's changelog: https://github.com/renovatebot/renovate/releases
#    Look for new managers ("ansible-galaxy", "dotnet-version", "github-runner", etc.)

# 2. If a new manager applies to this repo, add it to renovate.json:
#    "enabledManagers": [..., "new-manager"]
#    OR confirm config:recommended already includes it.

# 3. Test by triggering a dependency dashboard rebuild:
#    Comment "@renovate-bot recreate dashboard" on the open dashboard issue.
```

---

### What the cadence does NOT cover

- **Security patches between cadences.** If a CVE drops on Cilium/Traefik/CNPG and
  the fix is in a minor release, skip the cadence and bump immediately.
- **Reactive incident fixes.** A broken upstream that's blocking work jumps to the
  front of the queue.
- **One-time migrations** (e.g. switching a Helm chart's source). Those get their
  own runbooks/plan docs.

---

## 4. Troubleshooting

### Flux Image Update Stuck
```bash
kubectl describe imageupdateautomation flux-system -n flux-system
kubectl logs -n flux-system deployment/image-automation-controller
kubectl annotate --overwrite -n flux-system imageupdateautomation/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Kured Not Rebooting
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kured
# Note: Only reboots during 2-6am Pacific window
# Manual unlock if stuck:
kubectl annotate node <node-name> kured.dev/reboot-in-progress-
```

### Renovate Not Creating PRs
1. Check: https://developer.mend.io/github/etherport/infra
2. Look for "Action Required" issues
3. Verify `renovate.json` is valid

### Helm Upgrade Failed
```bash
helm status <release> -n <namespace>
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
```

---

## Related Documentation

- [kubernetes-upgrade.md](kubernetes-upgrade.md) - Detailed K8s upgrade procedures
- [image-pinning-policy.md](image-pinning-policy.md) - Which images are pinned how (Flux vs Renovate vs manual)
- [disaster-recovery.md](disaster-recovery.md) - Recovery procedures
- [operations-guide.md](operations-guide.md) - Command quick reference
