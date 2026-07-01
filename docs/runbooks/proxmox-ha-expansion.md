# Proxmox HA Expansion — from 1 to 2+ Nodes

## Current state (1 PVE node)

The homelab runs a single PVE host (`pve`). The per-VM hardware watchdog
(see `vm-watchdog.md`) is the *intended* tool for in-VM hangs — but it is
currently **non-functional/BLOCKED** (M91: the node kernel lacks the
`i6300esb` module, so it has never armed); VM-hang recovery today is
manual (`qm reset`).

**HA Manager adds no value on a single node** — it can only restart
VMs on the host they're already on, which the (working) watchdog design
would already cover.

## When to expand

Add a second PVE host when:
- A second physical machine is available (any small box: Mini PC, NUC,
  even an old desktop with 32+ GB RAM works fine)
- You want true host-failure recovery (PVE node crash → VMs migrate
  + restart elsewhere automatically)
- Storage is already shared (Ceph at 10.10.210.41 on dedicated VLAN 210 already is)

## Expansion plan

### 1. Provision the new PVE host

Manual ISO install of Proxmox VE on the new hardware. Use a
predictable hostname (`pve2`, `pve3`...) and the same network range
(10.10.201.0/24) so it's on the cluster network.

### 2. Initial cluster bootstrap via ansible

Add the new playbook (not yet committed; sketch below).

`infra/ansible/playbooks/proxmox-cluster.yml`:

```yaml
- name: Create or join Proxmox cluster
  hosts: pve_nodes
  become: true
  vars:
    cluster_name: wind-pve
    primary_pve: pve.wind.etherport.net
  tasks:
    - name: Check cluster status
      command: pvecm status
      register: pvecm_status
      changed_when: false
      failed_when: false

    - name: Create cluster on first node
      command: pvecm create {{ cluster_name }}
      when:
        - inventory_hostname == primary_pve
        - pvecm_status.rc != 0   # not already in a cluster

    - name: Join cluster from additional nodes
      command: >
        pvecm add {{ primary_pve }}
        --use_ssh 1
        --fingerprint "{{ primary_fingerprint }}"
      when:
        - inventory_hostname != primary_pve
        - pvecm_status.rc != 0
      # primary_fingerprint must be supplied via --extra-vars from the
      # output of `pvecm status | grep "Fingerprint"` on pve
```

This is a one-time bootstrap. Subsequent node adds re-run the same.

### 3. Verify cluster quorum

```bash
# On pve
pvecm status
# Quorum information should show 2 nodes if you added one,
# Expected votes: 2, Total votes: 2

# For 2-node clusters, add a QDevice (corosync external arbitrator)
# so a single node failure doesn't cost quorum. Run on a 3rd box
# (Raspberry Pi, NUC, or a small VM on the homelab network):
apt install corosync-qnetd
pvecm qdevice setup <qnetd-ip>
```

### 4. Enable Proxmox HA on critical VMs

Add to `infra/terraform/proxmox/ha/` (new module — not yet created):

```hcl
# HA group: defines failover topology
resource "proxmox_virtual_environment_hagroup" "k8s_cp" {
  group   = "k8s-control-plane"
  comment = "Control planes: prefer current host, restart-only"
  nodes = {
    pve  = 100  # priority on pve
    pve2 = 50
  }
  restricted = false
  no_failback = false
}

# HA resource: declares a VM as HA-managed
resource "proxmox_virtual_environment_haresource" "k8s_cp1" {
  resource_id = "vm:100"
  group       = proxmox_virtual_environment_hagroup.k8s_cp.group
  state       = "started"  # operator desired state
  comment     = "k8s-cp1"
}
# ...one per VM
```

Apply with `terraform apply -target=module.ha` after the cluster is
quorate.

### 5. Test failover

```bash
# Power off pve2 (or whichever node holds a non-primary CP)
ssh root@pve2 'poweroff'

# Within ~60s, HA Manager should migrate the affected VMs to pve.
# Verify:
ssh root@pve 'ha-manager status'
kubectl get nodes   # the affected node briefly NotReady, then re-Ready on new host
```

## Cost / hardware notes

- A new PVE host needs at minimum: 32 GB RAM, 8-core CPU, ~500 GB SSD
- Cluster network requires <1ms latency between PVE nodes (typically
  the same gigabit LAN is fine; corosync is sensitive to packet
  loss). Don't run PVE cluster across a flaky VPN.
- The existing external Ceph (10.10.210.41 on VLAN 210, dedicated storage
  network) is shared storage — VMs can live-migrate without storage
  replication.
- QDevice (3rd vote) avoids the "2-node split-brain" problem; a tiny
  always-on box on the network ($30 Raspberry Pi or VM elsewhere)
  suffices.

## What we have NOT done yet

- No `infra/terraform/proxmox/ha/` module — single-node PVE makes it
  moot. Skeleton above will land when there's a 2nd PVE host.
- No `proxmox-cluster.yml` ansible playbook — sketch above; finalise
  during expansion.
- TF watchdog blocks (in `k8s-vms/main.tf` etc.) are independent of
  HA and stay regardless.

The HA-related files will be added in a single commit when the
expansion happens; the runbook is the placeholder.
