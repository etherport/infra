# Proxmox VM Hardware Watchdog

## Purpose

Auto-recover Proxmox VMs from kernel hangs / userspace deadlocks without
manual `qm reset`. The Proxmox host emulates an i6300esb watchdog
device; the guest's `watchdog` daemon writes to `/dev/watchdog0` every
10 seconds; if writes stop for >30 seconds, Proxmox forcibly resets
the VM.

The K8s VM hang we saw in early 2026 (the one that needed manual
intervention) is the exact scenario this catches.

## Configuration

### Host side (Terraform)

In `infra/terraform/proxmox/k8s-vms/main.tf` and
`infra/terraform/proxmox/standalone-vms/main.tf`, each
`proxmox_virtual_environment_vm` resource has:

```hcl
watchdog {
  model  = "i6300esb"
  action = "reset"
}
```

`action = "reset"` triggers a hard reset (like power-cycle). Other
options: `shutdown` (graceful shutdown — defeats the purpose for
hangs), `poweroff` (hard power off, no auto-restart), `none` (alarm
only). Reset is the right choice for "VM is unresponsive, kick it."

### Guest side (Ansible)

`infra/ansible/playbooks/k8s-node-fixes.yml` installs the `watchdog`
package, writes `/etc/watchdog.conf`, and enables the systemd service.
The Packer base template (VM 9001) ships with the package installed
but the service **disabled** — the i6300esb device only exists when TF
attaches it, and starting the daemon without `/dev/watchdog0` would
crashloop.

Key `/etc/watchdog.conf` settings:
- `watchdog-device = /dev/watchdog0` — the PCI emulated device
- `watchdog-timeout = 30` — Proxmox resets if no write within 30s
- `interval = 10` — daemon writes every 10s (3x safety margin)
- `realtime = yes` + `priority = 1` — daemon scheduling priority so a
  CPU-bound process can't starve it
- `max-load-1 = 0` — don't kick the watchdog for load (load alone
  isn't a hang)

## Verifying it's working

Inside a guest:

```bash
# Device present?
ls -la /dev/watchdog0     # crw-rw---- 1 root root 10, 130 ...
sudo cat /sys/class/watchdog/watchdog0/identity   # i6300esb timer
sudo cat /sys/class/watchdog/watchdog0/timeout    # 30

# Daemon running + writing?
systemctl status watchdog
sudo journalctl -u watchdog --since '10 min ago' --no-pager
```

## Testing it actually resets the VM

**DO NOT do this on the only running K8s control plane.** Choose a
worker:

```bash
# On the chosen worker, lock up the kernel (sysrq trigger):
echo c | sudo tee /proc/sysrq-trigger
# OR run a CPU-spin process and `kill -STOP` the watchdog daemon
```

Within 30s the VM should hard-reset. From `pve` host:

```bash
qm config <vmid> | grep watchdog   # confirms attached
journalctl -u pve-ha-lrm -f         # if HA is also on, see triggers
```

## Caveats

- Watchdog catches **VM-level hangs** (kernel, userspace deadlocks).
  It does NOT catch application-level failures (kubelet stops
  reporting Ready, etc.) — that's the K8s control plane's job.
- An imported VM in `standalone-vms` (`vpn-local`, `dns-fallback`,
  `gh-runner` if applicable) needs a stop+start to attach the
  watchdog device. TF will trigger that on next `apply` if the
  watchdog block is newly added.
- Single-node Proxmox (current state): the watchdog resets the VM on
  the same host. If you expand to a Proxmox cluster (see
  `docs/runbooks/proxmox-ha-expansion.md`), HA Manager can additionally
  migrate VMs on host failure.
