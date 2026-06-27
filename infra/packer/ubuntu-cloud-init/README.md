# Ubuntu 24.04 Cloud-Init Template for Proxmox

This Packer template produces the reusable Ubuntu 24.04 LTS VM template
(**VM ID 9001**) in Proxmox that Terraform clones for each workload VM.
It is built by cloning a raw cloud-image base (**VM ID 9000**, created
once by `scripts/setup-cloud-base.sh`) and then layering homelab packages,
the netplan stanza for Multus VLAN parents, and the `ubuntu` cloud-init
user with the homelab SSH key.

## Features

- Ubuntu 24.04 LTS (Noble Numbat) cloud image
- Cloud-init enabled for Proxmox
- QEMU guest agent for better VM management
- Pre-installed packages: Python3, curl, wget, git, open-iscsi, nfs-common
- SSH key authentication only (password disabled)
- Q35 machine type with OVMF (UEFI) for GPU passthrough compatibility

## Prerequisites

1. **Packer installed** (v1.9+)
   ```bash
   brew install packer  # macOS
   ```

2. **Proxmox API token** with permissions:
   - VM.Allocate
   - VM.Clone
   - VM.Config.*
   - VM.Monitor
   - Datastore.AllocateSpace
   - Sys.Audit

3. **SSH key** at `~/.ssh/id_ed25519` (`ssh_private_key_file` default) — Packer's
   build-time key, paired with the `ssh_public_key` it bakes in as the per-host
   bootstrap seed; the running fleet is SSH cert-only (M76), this is build-only.

## Usage

### 1. Initialize Packer plugins

```bash
cd infra/packer/ubuntu-cloud-init
packer init .
```

### 2. Create variables file

```bash
cp variables.pkrvars.hcl.example variables.pkrvars.hcl
# Edit variables.pkrvars.hcl with your Proxmox credentials
```

### 3. Ensure base template VM 9000 exists on PVE

Packer clones from VM **9000** (raw Ubuntu cloud image, created
once by `scripts/setup-cloud-base.sh`) and produces VM **9001**
(customised template Terraform clones from for each workload VM).

If 9000 doesn't exist yet, on the PVE host:
```bash
sudo bash scripts/setup-cloud-base.sh
```

### 4. Build the template (VM 9001)

```bash
packer build -var-file=variables.pkrvars.hcl .
```

This will:
1. Clone VM 9000 → temporary build VM
2. apt upgrade + install homelab base packages
3. Write `/etc/netplan/51-vlan-interfaces.yaml` (Multus VLAN parents)
4. Clean cloud-init state + machine-id for templating
5. Convert to template at ID **9001**

### 5. Verify the template

```bash
# SSH to Proxmox and check
pvesh get /nodes/pve/qemu/9001/config
```

## Rebuilding the Template

To update the template (e.g., for new Ubuntu patches):

```bash
# Packer is invoked with -force which destroys the existing 9001 first;
# no manual `pvesh delete` is required.

# Rebuild
packer build -var-file=variables.pkrvars.hcl .
```

Or use the GitHub Actions workflow (if configured):
```bash
gh workflow run packer-ubuntu-template.yml -f action=build
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `proxmox_url` | `https://pve.wind.etherport.net:8006/api2/json` | Proxmox API URL |
| `proxmox_node` | `pve` | Proxmox node name |
| `template_vm_id` | `9001` | VM ID for the Packer-built template (clone source for Terraform) |
| `template_name` | `ubuntu-2404-cloud-init` | Template name |
| `storage_pool` | `local-zfs` | Storage pool for VM disks |
| `ssh_username` | `ubuntu` | Default cloud-init user baked into the template (with the `automation@homelab` bootstrap pubkey) |

## What's Installed

- **System**: Ubuntu 24.04 LTS, fully updated
- **User**: `ubuntu` (cloud-init) with the `automation@homelab` pubkey baked as a
  per-host **bootstrap seed** (stripped post-enrolment, M76 — the fleet is SSH cert-only)
- **Packages**:
  - `qemu-guest-agent` - VM management
  - `cloud-init`, `cloud-guest-utils` - Cloud provisioning
  - `python3`, `python3-pip` - Ansible requirement
  - `open-iscsi`, `nfs-common` - Storage connectivity
  - `curl`, `wget`, `git`, `vim`, `htop` - Utilities
- **Netplan**: `/etc/netplan/51-vlan-interfaces.yaml` baked in to bring up
  the `enp6s19/20/21` Multus VLAN parent interfaces on first boot (see
  `docs/runbooks/vlan-interfaces-netplan.md` and
  `platform/kubernetes/multus/README.md`).

## Integration with Terraform

The Terraform configs in `infra/terraform/proxmox/` clone from this template:

```hcl
clone {
  vm_id = 9001  # This template (Packer-built; 9000 is the raw base)
  full  = true
}
```

## Troubleshooting

### Build hangs at "Waiting for SSH"
- Check Proxmox firewall allows outbound connections
- Verify the VM gets a DHCP address
- Check Proxmox console for autoinstall errors

### Template already exists
- Delete first: ``
- Or change `template_vm_id` in variables

### Permission denied
- Verify API token has required permissions
- Check token isn't expired
