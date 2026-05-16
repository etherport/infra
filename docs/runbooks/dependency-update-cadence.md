# Dependency update cadence

How updates flow into this repo, and where you need to step in by hand.

## At a glance

| Cadence  | Trigger                  | Time    | What to do                                                    |
|----------|--------------------------|---------|---------------------------------------------------------------|
| Weekly   | Renovate PRs in GitHub   | ~15 min | Triage, approve minors, defer majors                          |
| Monthly  | Calendar reminder        | ~30 min | Rebuild Packer template + check Flux image automation         |
| Quarterly| Calendar reminder        | ~2 hrs  | Walk the manual list (K8s, OS, Proxmox, majors)               |
| Annually | Calendar reminder        | ~1 hr   | Refresh `renovate.json` against latest preset coverage        |

## Weekly — Renovate triage

```bash
gh pr list --label renovate
```

For each PR:
- **Patch/minor on infra (TF providers, GH Actions, Helm minors, container minors)** → review the changelog link in the PR body, merge if no breaking notes. Flux/CI takes it from there.
- **Major** on anything stateful (Cilium, CNPG, cert-manager, Traefik, Flux, kubespray itself) → close with comment, schedule for the next quarterly window. Don't auto-merge majors.
- **A PR that's been open >2 weeks** → either merge or close. Stale Renovate PRs accumulate merge conflicts and stop being useful.

## Monthly — Packer rebuild + Flux automation check

**1. Rebuild VM 9001 to refresh Ubuntu kernel + baked tools.**

```bash
cd infra/packer/ubuntu-cloud-init
packer build .
# Packer destroys + recreates VM 9001 on PVE. Subsequent standalone-vms
# applies will pick up the new template on next clone.
```

If a service VM is rebuilt this month anyway (e.g. you destroyed dns-fallback for a fix), it picks up the new base. Otherwise the old VMs keep their old kernel until you trigger a rebuild.

**2. Verify Flux image automation is actually firing for the deny-listed images.**

These images are excluded from Renovate because Flux handles them via `ImagePolicy` CRDs:
`ollama`, `open-webui`, `technitium/dns-server`, `requarks/wiki`, `plexinc/pms-docker`, `kopia/kopia`, `rclone/rclone`, `home-assistant`, `python`, `busybox`, `sparked-diamond/*`.

```bash
flux get image policy -A
# Each policy should show a recent LATEST IMAGE. If LAST UPDATED is
# weeks/months old, the policy isn't matching new tags — check
# the regex against the registry tags page.

flux get image update -A
# ImageUpdateAutomation must be Ready=True. If not, Flux is finding
# new images but failing to commit the bumps to git.
```

If any policy is stale, treat that image as **manually maintained** for now: check the registry, bump the tag in the Flux resource by hand, fix the ImagePolicy regex in a follow-up.

## Quarterly — the manual list

A Saturday morning's work. Pick a quarter-aligned weekend.

**1. Kubernetes minor upgrade** (e.g. 1.31 → 1.32):

```bash
# Edit infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml
# Bump `kube_version: v1.X.Y`
# Run the upgrade playbook from infra/kubespray/:
ansible-playbook -i ../ansible/inventory/wind/inventory.ini \
  upgrade-cluster.yml --private-key /tmp/auto-key
```

See `docs/runbooks/kubernetes-upgrade.md` for the full procedure (CP-then-workers, addon validation, smoke tests).

**2. Proxmox VE apt upgrade:**

```bash
ssh root@pve.wind.etherport.net "apt update && apt dist-upgrade -y"
# Reboot only during a planned maintenance window — kicks every VM.
```

**3. Ubuntu LTS check.** Currently 24.04. New LTS lands every 2 years (next: 26.04 in April 2026). When ready, bump the cloud-image URL in `infra/packer/ubuntu-cloud-init/` and rebuild VM 9001.

**4. Major-version PRs from Renovate.** Re-open the ones you closed during weekly triage. Plan + apply in this window with downtime budget.

**5. Shell-installed binaries** — the blind spot Renovate can't touch:
- `.NET runtime` in `infra/ansible/playbooks/technitium.yml` (channel `X.Y` — check [dotnet.microsoft.com/download](https://dotnet.microsoft.com/download) for current support)
- Any `curl ... | sh` install in Packer / Ansible
- Kubespray git ref (if pinned vs floating)

Grep for these once per quarter:

```bash
grep -rEn "dotnet-install\.sh|curl.*\|\s*(sh|bash)|wget.*\.tar\.gz" \
  infra/ansible infra/packer | grep -v "^Binary"
```

For each hit, check the upstream for a newer version, bump in the playbook, document the change in a comment.

## Annually — refresh Renovate preset

```bash
# 1. Skim Renovate's changelog: https://github.com/renovatebot/renovate/releases
#    Look for new managers ("ansible-galaxy", "dotnet-version", "github-runner", etc.)

# 2. If a new manager applies to this repo, add it to renovate.json:
#    "enabledManagers": [..., "new-manager"]
#    OR confirm config:recommended already includes it.

# 3. Test by triggering a dependency dashboard rebuild:
#    Comment "@renovate-bot recreate dashboard" on the open dashboard issue.
```

## What this does NOT cover

- **Security patches between cadences.** If a CVE drops on Cilium/Traefik/CNPG and the fix is in a minor release, skip the cadence and bump immediately.
- **Reactive incident fixes.** A broken upstream that's blocking work jumps to the front of the queue.
- **One-time migrations** (e.g. Cilium to Hubble, switching a Helm chart's source). Those get their own change docs in `docs/migrations/`.
