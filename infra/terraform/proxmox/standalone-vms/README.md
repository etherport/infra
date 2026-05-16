# Proxmox Standalone VMs

Terraform module that provisions homelab service VMs **outside** the K8s
cluster. Each is a clone of VM 9001 (the Packer-built Ubuntu 24.04
template) configured via cloud-init.

## Inventory

| VM ID | Name           | IP             | Role                                                     |
|-------|----------------|----------------|----------------------------------------------------------|
| 1001  | dns-fallback   | 10.10.201.6    | Technitium DNS secondary (failover for K8s technitium .5)|
| 1002  | vpn-local      | 10.10.201.15   | WireGuard site-to-site to AWS (VRRP BACKUP for the K8s WG pod) |
| 1003  | gh-runner      | 10.10.201.30   | GitHub Actions `[self-hosted, lifecycle]` runner for K8s/Proxmox workflows |

Configuration baseline (applied to every standalone VM by the TF):

- Clones from VM 9001 (Packer template — Ubuntu 24.04, qemu-guest-agent,
  netplan for VLAN parents, watchdog package preinstalled-but-disabled)
- `initialization.user_account` user `ubuntu` with the `var.ssh_public_key`
  authorized key (the homelab automation key from 1Password)
- `initialization.dns.servers = ["10.10.201.5", "10.10.201.6"]` — no public
  DNS fallback (see commit `85079ba` for context)
- Hardware watchdog (`i6300esb`, `action: reset`) attached on initial CREATE
  only — `lifecycle.ignore_changes = [watchdog]` prevents subsequent applies
  from re-mutating the device (see "gh-runner self-kill" below)

Per-service configuration is applied via Ansible playbooks in
`infra/ansible/playbooks/`:

| VM           | Playbook         | Notes                                                              |
|--------------|------------------|--------------------------------------------------------------------|
| dns-fallback | `technitium.yml` | Installs Technitium, sets admin password from SOPS, creates wind.etherport.net zone + forwarders. Idempotent. |
| vpn-local    | `wireguard.yml`  | Installs WG + Keepalived; loads peer keys from SOPS. Idempotent.   |
| gh-runner    | `gh-runner.yml`  | Installs the GH Actions runner binary, registers with the repo.    |

## Operator prerequisites

Before running TF apply or any ansible playbook against these VMs,
make sure these are in place on your workstation:

| Prereq                            | Where it goes                          | Source                                                       |
|-----------------------------------|----------------------------------------|--------------------------------------------------------------|
| SSH private key                   | `/tmp/auto-key` (mode `0600`)          | 1Password — item "Homelab Automation SSH Key" → private key  |
| SOPS age key                      | `~/.config/sops/age/keys.txt`          | 1Password — item "SOPS Age Key (homelab)" → key body         |
| `sops` binary                     | on `$PATH`                             | `brew install sops`                                          |
| `ansible-playbook` binary         | on `$PATH`                             | `brew install ansible` (or `pipx install ansible-core`)      |
| `gh` CLI (only for GH Actions path) | on `$PATH`                           | `brew install gh` and `gh auth login`                        |
| `terraform` binary (only for local-apply path) | on `$PATH`              | `brew install terraform`                                     |
| AWS credentials (only for local-apply path) | env or profile             | 1Password — item "AWS — claude-admin IAM keys"               |
| Proxmox API token (only for local-apply path) | env vars                | 1Password — item "Proxmox VE Terraform Token"                |

Quick verification:

```bash
ls -la /tmp/auto-key                   # exists, mode 0600
ls -la ~/.config/sops/age/keys.txt     # exists, mode 0600
sops -d infra/ansible/playbooks/../../../platform/kubernetes/technitium/05-secret.sops.yaml >/dev/null && echo "sops ok"
which ansible-playbook gh terraform
```

If you've previously SSH'd to a VM that was later destroyed + recreated
(e.g. dns-fallback rebuild), clear the stale host key first or `ansible`
will refuse to connect:

```bash
ssh-keygen -R 10.10.201.6   # dns-fallback
ssh-keygen -R 10.10.201.15  # vpn-local
ssh-keygen -R 10.10.201.30  # gh-runner
```

The inventory's `ansible_ssh_common_args` includes `StrictHostKeyChecking=accept-new`
which auto-accepts *new* hosts, but rejects *changed* host keys for safety.

## Apply path: GitHub Actions (default)

The standard apply path goes through the workflow
`.github/workflows/terraform-proxmox-standalone-vms.yml`:

- **Push to main touching `infra/terraform/proxmox/standalone-vms/**`** → automatic `plan` run
- **Manual `workflow_dispatch` with `action: apply`** → apply

```bash
gh workflow run terraform-proxmox-standalone-vms.yml -f action=apply
gh run watch  # watch the run; the apply runs on the gh-runner VM (1003)
```

After a successful apply, run the service-specific ansible against the
newly created VMs:

```bash
cd infra/ansible
ansible-playbook -i inventory/wind/inventory.ini playbooks/technitium.yml --limit dns-fallback \
  --private-key /tmp/auto-key -u ubuntu --become
ansible-playbook -i inventory/wind/inventory.ini playbooks/wireguard.yml --limit vpn-local \
  --private-key /tmp/auto-key -u ubuntu --become
```

(The Ansible playbooks set the technitium admin password, create zones, install WireGuard,
etc. — see their headers for details.)

## gh-runner self-kill — why ignore_changes is on watchdog

Any TF mutation that requires a stop+start of vm 1003 (gh-runner) is
fatal when the apply is **running on** gh-runner. Hit this on 2026-05-16
when adding the watchdog device — VM stopped mid-job, runner paused,
workflow cancelled, TF state ended up half-applied (one VM destroyed,
its replacement uncreated, S3 state lock held).

To prevent recurrence, the `proxmox_virtual_environment_vm.standalone`
resource has:

```hcl
lifecycle {
  ignore_changes = [watchdog]
}
```

This guard does **not** prevent the watchdog from being attached to
NEW VMs — it only stops TF from mutating the device on already-created
VMs. So a fresh dns-fallback or vpn-local creation still gets the
watchdog correctly.

If you genuinely need to change watchdog config (e.g. switch action
from `reset` to `shutdown`), you cannot do it through the standard
GH Actions apply path — you must use one of the local-apply paths
below.

## Apply path: local Terraform (when gh-runner can't be the runner)

Three scenarios where you need to bypass the GH workflow:

1. **gh-runner itself is the VM being modified** (e.g. CPU/memory bump,
   network device add, watchdog change).
2. **gh-runner is down** (e.g. waiting on VM rebuild — chicken/egg).
3. **You want to inspect state directly** (`terraform state list`,
   `terraform state rm`, `terraform import`).

Procedure:

```bash
# 1. Get on the homelab VPN (TF reaches Proxmox API at pve.wind.etherport.net:8006)
#    Verify: dig pve.wind.etherport.net should return 10.10.200.41

# 2. cd to the module
cd ~/code/infra/infra/terraform/proxmox/standalone-vms

# 3. Init (downloads providers, hooks up S3 backend)
terraform init

# 4. Pull AWS + Proxmox credentials.
#    AWS: aws-vault, direnv, or shell exports. The S3 state backend
#         uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars
#         from your normal profile.
#    Proxmox: TF_VAR_proxmox_token_id + TF_VAR_proxmox_token_secret
#             from 1P item "Proxmox VE Terraform Token".
export TF_VAR_proxmox_token_id="$(op read 'op://Private/Proxmox VE Terraform Token/token id')"
export TF_VAR_proxmox_token_secret="$(op read 'op://Private/Proxmox VE Terraform Token/token secret')"

# 5. Plan-first ALWAYS (this is shared state — see what TF wants to do)
#    For runner-touching changes, scope with -target:
terraform plan -target='proxmox_virtual_environment_vm.standalone["gh-runner"]'

# 6. Review the plan output. If acceptable:
terraform apply -target='proxmox_virtual_environment_vm.standalone["gh-runner"]'

# 7. If gh-runner stops as part of the change, give it ~60s to restart.
#    qemu-guest-agent reports the IP back to PVE → TF considers the
#    resource complete. SSH check:
ssh -i /tmp/auto-key ubuntu@10.10.201.30 hostname
```

## Force-unlock procedure (when a previous apply crashed)

The S3 state backend uses **native S3 locking** (no DynamoDB) — the lock
is a `.tflock` sidecar object. If an apply terminates abruptly (workflow
cancellation, network drop, OOM), the lock can survive and block the
next apply with `Error acquiring the state lock`.

Steps:

```bash
# 1. Get the lock ID from the error message. Look for the `ID:` field
#    in the Lock Info block in stderr / workflow log.

# 2. From your Mac (local TF — same setup as the local-apply path above):
cd ~/code/infra/infra/terraform/proxmox/standalone-vms
terraform init

# 3. Force-unlock. Confirm with "yes".
terraform force-unlock <lock-id>

# 4. Re-run the apply (GH workflow or local).
```

Don't `aws s3 rm` the lock object directly — the IAM `claude-admin`
user can't (correctly least-privilege) and even the operator account
should prefer `terraform force-unlock` so the operation is audited
in your shell history.

## Adding a new standalone VM

1. Edit `main.tf` — add a new entry to `local.standalone_vms`:

   ```hcl
   new-service = {
     vm_id       = 1004           # next free in 1000-1099 range
     ip          = "10.10.201.31"
     vcpus       = 2
     memory_mb   = 2048
     disk_gb     = 20
     description = "..."
     tags        = ["terraform", "new-service", "standalone"]
   }
   ```

2. Add an ansible playbook `infra/ansible/playbooks/<new-service>.yml`
   that does the per-service install.

3. Add the host to `infra/ansible/inventory/wind/inventory.ini` under
   `[all]` and any service-specific groups.

4. `gh workflow run terraform-proxmox-standalone-vms.yml -f action=apply`
   (or local apply per the procedure above).

5. `ansible-playbook ... --limit new-service` to configure the service.

## See also

- Per-service runbooks: `docs/runbooks/cert-manager-wildcard.md`,
  `docs/runbooks/aws-private-dns.md`, etc.
- VM template Packer build: `infra/packer/ubuntu-cloud-init/`
- Watchdog config: `docs/runbooks/vm-watchdog.md`
- GH Actions runner setup: `infra/ansible/playbooks/gh-runner.yml`
