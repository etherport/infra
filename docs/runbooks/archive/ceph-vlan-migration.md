# Ceph VLAN migration runbook (2026-05-18)

Migrating the Ceph cluster from VLAN 201 (`10.10.201.41`) to a dedicated
storage VLAN 210 (`10.10.210.41`). Prerequisite for the Proxmox SDN migration
(#19) — VLAN 201 currently has a `vmbr0.201` host sub-interface holding Ceph,
which collides with any SDN VNet on that VLAN.

## State (pre-migration)

- **Ceph topology:** single-node, single-monitor `mon.pve` on PVE host. fsid
  `4de37616-ef82-4295-8ff0-7309d4b34812`. `osd_pool_default_size = 2`.
- **Ceph endpoint today:** `10.10.201.41:3300` (mon v2), `:6789` (mon v1),
  `:6800-6819` (OSDs/MGR).
- **Clients:** PVE itself; K8s via `ceph-csi` driver pointing at
  `10.10.201.41:6789` (see `platform/kubernetes/storage/ceph-csi/csi-config-map.yaml`).
- **K8s PVCs on `ceph-rbd`:** 21 across 11 namespaces — postgres (CNPG),
  monitoring (alertmanager + prometheus), technitium (DNS, 2x StatefulSet),
  home-assistant, plex, ollama, wikijs, traefik, kopia, ha-config.
- **VM disks on Ceph:** none. All K8s + standalone VMs use `local-zfs`.
- **Internal DNS continuity:** `dns-fallback` VM (1001 on `local-zfs`) stays
  up throughout. K8s technitium pods go down. Set Mac resolver to .6 first.

## State (post-migration target)

- Ceph mon binds on `10.10.210.41:6789` + `:3300`. OSDs follow.
- K8s ceph-csi points to `10.10.210.41:6789`.
- PVE host has `vmbr0.210` (storage) instead of `vmbr0.201`. VLAN 201 has
  no PVE host attachment.

## Pre-requisites

- [ ] iKVM session open to PVE BMC (https://10.10.200.21) AND tested.
- [ ] `/etc/pve/ceph.conf` backed up locally:
      `scp graham@pve:/etc/pve/ceph.conf /tmp/ceph.conf.pre-migration`
- [ ] Current `ceph -s` healthy, no rebalancing in progress.
- [ ] DNS resolver on operator's Mac set to `10.10.201.6` (dns-fallback) so
      name resolution survives technitium downtime:
      `networksetup -setdnsservers Wi-Fi 10.10.201.6`
      (revert with `-setdnsservers Wi-Fi empty` after)
- [ ] Recent Velero / kopia backups for tier-1 PVCs (CNPG, technitium).
      `velero backup get | head -5`
- [ ] `infra/terraform/unifi/networks.tf` `unifi_network "ceph"` has landed
      and `terraform plan` is clean.

## Phase 1 — UniFi network + Ceph storage sub-interface on PVE

**Goal:** VLAN 210 exists, PVE host listens on `10.10.210.41`. Ceph itself
not touched yet. Zero workload impact.

```bash
# 1.1 Confirm Unifi network is in place (you've already created in UI)
#     This step is a TF import; should be no-op after.
gh workflow run terraform-unifi.yml -f action=plan
# Expect: "No changes" or import for unifi_network.ceph

# 1.2 Add vmbr0.210 stanza to PVE via Ansible
cd infra/ansible
ansible-playbook -i inventory/wind/ playbooks/pve-network.yml --check --diff
# Verify the diff adds the expected stanza (auto vmbr0.210 + iface block).
ansible-playbook -i inventory/wind/ playbooks/pve-network.yml --diff

# 1.3 Verify from PVE
ssh graham@pve 'ip -4 addr show vmbr0.210'
# Expect: inet 10.10.210.41/24

# 1.4 Verify from somewhere else on VLAN 210 (UDM, switch, or a K8s node
#     after Phase 2)
ping 10.10.210.41
```

**Rollback:** `ssh graham@pve 'cp /etc/network/interfaces.bak-* /etc/network/interfaces; ifreload -a'`

## Phase 2 — K8s reachability to VLAN 210 (Multus secondary NIC)

**Goal:** K8s nodes have an interface on VLAN 210 so ceph-csi traffic stays
in-kernel on PVE (same host).

Edits in `infra/terraform/proxmox/k8s-vms/main.tf`:
- Add a 5th `network_device` block to each VM with `bridge = "vmbr0"`,
  `vlan_id = 210`, `model = "virtio"`.
- Apply per-VM with drain/migrate/uncordon cycle.

Multus NetworkAttachmentDefinition for VLAN 210 in
`platform/kubernetes/multus/` (mirror existing pattern for 202/204/205).

Static IPs for K8s nodes on VLAN 210 (out of the DHCP 100-254 pool):
- k8s-cp1: `10.10.210.50`
- k8s-cp2: `10.10.210.51`
- k8s-cp3: `10.10.210.52`
- k8s-w1: `10.10.210.53`
- k8s-w2: `10.10.210.54`
- k8s-w3: `10.10.210.55`
- k8s-w4: `10.10.210.56`
- k8s-gpu1: `10.10.210.60`

Add reservations in `infra/terraform/unifi/reservations.tf`.

**Verify after each VM:**
```bash
kubectl get pod -A -o wide  # ensure all pods still running on that node
ssh ubuntu@10.10.201.<NN> 'ip -4 addr show'  # should show new VLAN 210 IP
```

**Rollback per-VM:** revert that VM's network_device block, `terraform apply -target=...`.

## Phase 3 — Ceph cutover (the maintenance window)

**Estimated downtime: 10-30 min** for all Ceph-backed K8s PVCs. Plan around
this. Local-zfs-backed VMs (all of them) are unaffected.

### Step 3.1 — Quiesce Ceph clients

```bash
# Scale Flux down so it doesn't keep re-applying things
kubectl -n flux-system scale deploy --replicas=0 --all
# Wait for current Flux reconciliations to stop
sleep 30

# Scale all Ceph-dependent workloads to 0
# (these are by-namespace; tweak based on what's running)
kubectl -n postgres scale cluster postgres-cluster --replicas=0
kubectl -n dns scale statefulset technitium --replicas=0
kubectl -n monitoring scale deploy monitoring-grafana --replicas=0
kubectl -n monitoring scale statefulset alertmanager-monitoring-kube-prometheus-alertmanager --replicas=0
kubectl -n monitoring scale statefulset prometheus-monitoring-kube-prometheus-prometheus --replicas=0
kubectl -n home-automation scale deploy home-assistant --replicas=0
kubectl -n plex scale deploy plex --replicas=0
kubectl -n ollama scale deploy ollama --replicas=0
kubectl -n ollama scale deploy open-webui --replicas=0
kubectl -n wikijs scale deploy wiki-js --replicas=0
kubectl -n traefik delete pod -l app=traefik  # ceph-pvc-using replicas; redeployed later
kubectl -n backups scale deploy kopia --replicas=0  # if you have kopia deployment

# Verify no pods are using ceph-rbd PVCs anymore
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{","}{end}{"\n"}{end}' | grep -v ': $' | head
```

### Step 3.2 — Backup Ceph state (on PVE)

```bash
sudo bash -c '
  ceph -s > /root/ceph-pre-migration.txt
  ceph mon dump > /root/ceph-monmap-pre.txt
  ceph mon getmap -o /root/ceph-monmap-pre.bin
  cp /etc/pve/ceph.conf /root/ceph.conf.pre-migration
  date
' 
```

### Step 3.3 — Stop Ceph daemons

```bash
sudo systemctl stop ceph.target
# Wait until no Ceph processes listening
sudo ss -tlnp 2>/dev/null | grep -E ':(3300|6789|68[0-9]{2})\s' || echo "ceph stopped"
```

### Step 3.4 — Reconfigure `ceph.conf` and monmap

```bash
sudo tee /etc/pve/ceph.conf <<'EOF'
[global]
    auth_client_required = cephx
    auth_cluster_required = cephx
    auth_service_required = cephx
    cluster_network = 10.10.210.0/24
    fsid = 4de37616-ef82-4295-8ff0-7309d4b34812
    mon_allow_pool_delete = true
    mon_host = 10.10.210.41
    ms_bind_ipv4 = true
    ms_bind_ipv6 = false
    osd_pool_default_min_size = 2
    osd_pool_default_size = 2
    public_network = 10.10.210.0/24

[client]
    keyring = /etc/pve/priv/$cluster.$name.keyring

[client.crash]
    keyring = /etc/pve/ceph/$cluster.$name.keyring

[mon.pve]
    public_addr = 10.10.210.41
EOF
```

Rewrite the monmap (single-mon case, simplest):

```bash
sudo monmaptool --create --add pve 10.10.210.41 --fsid 4de37616-ef82-4295-8ff0-7309d4b34812 /tmp/monmap-new --clobber
sudo ceph-mon -i pve --inject-monmap /tmp/monmap-new
```

### Step 3.5 — Start Ceph

```bash
sudo systemctl start ceph.target
sleep 10
sudo ceph -s
# Expect: HEALTH_OK eventually. Initially HEALTH_WARN about clock skew or
# OSDs reconnecting is normal — wait up to 5 min.
sudo ss -tlnp 2>/dev/null | grep -E '10\.10\.210\.41:(3300|6789|68[0-9]{2})'
# Expect: mon listening on .210.41:3300+6789, OSDs on .210.41:680N
```

### Step 3.6 — Update K8s `ceph-csi-config`

In `platform/kubernetes/storage/ceph-csi/csi-config-map.yaml`:

```yaml
data:
  config.json: |-
    [
      {
        "clusterID": "4de37616-ef82-4295-8ff0-7309d4b34812",
        "monitors": [
          "10.10.210.41:6789"
        ]
      }
    ]
```

Commit + push. Then immediately:

```bash
# Bring Flux back up so it reconciles the new configmap
kubectl -n flux-system scale deploy --replicas=1 --all
# Force Flux to reconcile now (instead of waiting 1min)
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# After configmap applied, bounce ceph-csi pods so they pick up new mon
kubectl -n ceph-csi-rbd delete pod -l app=ceph-csi-rbd
# Wait for them to be Running
kubectl -n ceph-csi-rbd get pod -w
```

### Step 3.7 — Bring workloads back

```bash
# In reverse order of step 3.1
kubectl -n backups scale deploy kopia --replicas=1
kubectl -n wikijs scale deploy wiki-js --replicas=1
kubectl -n ollama scale deploy open-webui --replicas=1
kubectl -n ollama scale deploy ollama --replicas=1
kubectl -n plex scale deploy plex --replicas=1
kubectl -n home-automation scale deploy home-assistant --replicas=1
kubectl -n monitoring scale statefulset prometheus-monitoring-kube-prometheus-prometheus --replicas=2
kubectl -n monitoring scale statefulset alertmanager-monitoring-kube-prometheus-alertmanager --replicas=2
kubectl -n monitoring scale deploy monitoring-grafana --replicas=1
kubectl -n dns scale statefulset technitium --replicas=2
kubectl -n postgres scale cluster postgres-cluster --replicas=3
```

### Step 3.8 — Verify

```bash
# All ceph-rbd PVCs Bound, no Pending
kubectl get pvc -A | grep ceph-rbd | grep -v Bound

# Tier-1 services
curl -sk https://10.10.201.5:5380/api/dashboard/stats.heapStats > /dev/null && echo "technitium OK"
kubectl exec -n postgres postgres-cluster-1 -- psql -U postgres -c 'SELECT now()' | head -3
curl -sk https://traefik.wind.etherport.net/ -o /dev/null -w "traefik=%{http_code}\n"

# Ceph health
ssh graham@pve 'sudo ceph -s'
# Want: HEALTH_OK
```

## Phase 4 — Clean up `vmbr0.201` on PVE

After Ceph has been on VLAN 210 for at least 24h and all dependent
workloads have been verified happy:

```bash
cd infra/ansible
ansible-playbook -i inventory/wind/ playbooks/pve-network.yml \
  -e pve_network_action=remove_workload_subif --check --diff
# Verify diff removes only the vmbr0.201 block.
ansible-playbook -i inventory/wind/ playbooks/pve-network.yml \
  -e pve_network_action=remove_workload_subif --diff
```

The playbook has a guard that aborts if Ceph is still listening on
`10.10.201.41:3300|6789` — won't let us remove the sub-interface while it's
still load-bearing.

## Phase 5 — Now SDN migration can proceed (issue #19)

VLAN 201 now has no PVE host sub-interface. The `servers` VNet
(VLAN 201) can be added to the SDN module. Resume from where the
post-incident plan left off:

1. Re-add `servers` VNet to `infra/terraform/proxmox/sdn/vnets.tf` (it's
   currently dropped; uncomment + restore)
2. `gh workflow run terraform-proxmox-sdn.yml -f action=apply`
3. Migrate VMs to `bridge = "servers"` etc. per the original 6-PR plan.

## Total rollback (worst case)

If Phase 3 fails partway through:

1. From PVE iKVM: `cp /root/ceph.conf.pre-migration /etc/pve/ceph.conf`
2. Restore monmap: `monmaptool --create --add pve 10.10.201.41 --fsid 4de37616-ef82-4295-8ff0-7309d4b34812 /tmp/monmap-rollback --clobber; ceph-mon -i pve --inject-monmap /tmp/monmap-rollback`
3. `systemctl restart ceph.target`
4. Revert `csi-config-map.yaml` in git, push, force Flux reconcile.

## Open items

- **L3 routing verification:** confirm "Switch Rack PoE" (US624P) is actually
  routing VLAN 210 — UI-only field, not in TF. Test by pinging the gateway
  `10.10.210.1` from another VLAN.
- **DNS records:** add `pve-storage.wind.etherport.net → 10.10.210.41` to the
  technitium zone for naming clarity.
- **PromQL alert:** add alert for `ceph_mon_metadata` showing the right
  address (catch accidental drift back).
