# GPU Node — Disable Secure Boot

## Problem

On VM 120 (k8s-gpu1), the NVIDIA driver daemonset (gpu-operator) fails with:

```
modprobe: ERROR: could not insert 'nvidia': Key was rejected by service
```

The Tesla P40 (Pascal) is too old to use NVIDIA's open kernel modules
(those require Turing+). The out-of-tree NVIDIA modules are not signed by
the Canonical UEFI CA, so Ubuntu's Secure Boot lockdown rejects them.

## Root cause

`/Users/grahamsmith/code/infra/infra/terraform/proxmox/k8s-vms/main.tf:248`
declares `pre_enrolled_keys = false` on the GPU node's EFI disk, but the
`bpg/proxmox` provider does not expose a `secure_boot` toggle. The EFI
vars layer in the cloud image still has SB enabled.

## Permanent fix (one-time, ~5 min downtime on VM 120)

```bash
# 1. Stop the VM
ssh root@pve.wind.etherport.net 'qm stop 120'

# 2. Delete + recreate the EFI disk without pre-enrolled keys
ssh root@pve.wind.etherport.net \
  'qm set 120 --delete efidisk0 && \
   qm set 120 --efidisk0 local-zfs:0,efitype=4m,pre-enrolled-keys=0'

# 3. Boot the VM
ssh root@pve.wind.etherport.net 'qm start 120'
```

Wait ~3 minutes after start. The NVIDIA driver pod is already in a
restart loop; once `modprobe nvidia` succeeds it writes
`/run/nvidia/validations/driver-ready` and the remaining gpu-operator
init containers complete. Plex + Ollama pods leave `Pending`.

## Verification

```bash
# On k8s-gpu1
sudo mokutil --sb-state    # → SecureBoot disabled
lsmod | grep -E 'nvidia|nvidia_uvm|nvidia_modeset'

# In K8s
kubectl get nodes -l nvidia.com/gpu.present=true
kubectl get pods -n gpu-operator-system   # all Running/Completed
kubectl get pods -n plex,ollama           # should leave Pending
```

## Why not via Terraform

The bpg/proxmox provider as of v0.106 has no `secure_boot` knob. The
audit looked at `replace_triggered_by` on the `efi_disk` block but that
would force the WHOLE VM resource to be recreated — destructive. The
clean automation path is to wrap the `qm set --efidisk0 ...` sequence in
a `null_resource` with `local-exec` connecting via SSH; that requires a
PVE root SSH key in the runner. Workaround above is faster.
