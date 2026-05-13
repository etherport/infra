# Multus CNI - Multi-Network Support

Multus CNI enables attaching multiple network interfaces to Kubernetes pods. This is used for:
- Home Assistant: Access to multiple VLANs for device discovery
- Future multi-homed workloads

## Architecture

- **Namespace**: `multus-system` - Dedicated namespace for NAD resources (shared across workloads)
- **Primary CNI**: Cilium (cluster networking)
- **Secondary CNI**: macvlan (direct VLAN access)

## Installation

### Option 1: Via Kubespray (Recommended)

Update Kubespray inventory:
```yaml
# inventory/wind/group_vars/k8s_cluster/k8s-cluster.yml
kube_network_plugin_multus: true

# inventory/wind/group_vars/k8s_cluster/k8s-net-cilium.yml
cilium_cni_exclusive: false
```

Re-run Kubespray:
```bash
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh cluster.yml --tags network
```

### Option 2: Manual Installation

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.1.0/deployments/multus-daemonset-thick.yml
```

## Verification

```bash
# Check Multus pods are running
kubectl get pods -n kube-system | grep multus

# Check CNI configuration
kubectl get ds -n kube-system kube-multus-ds

# Verify NADs
kubectl get network-attachment-definitions -n multus-system
```

## NetworkAttachmentDefinitions

NADs are deployed in the `multus-system` namespace and can be used by pods in any namespace. See `network-attachment-definitions/` for VLAN configurations.

Current VLANs:
- `vlan202-client`: 10.10.202.0/24 (Client devices)
- `vlan204-iot`: 10.10.204.0/24 (IoT devices)
- `vlan205-security`: 10.10.205.0/24 (Security devices)

## Usage

Annotate pods with network attachments using `namespace/name` syntax:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {
          "name": "multus-system/vlan202-client",
          "ips": ["10.10.202.x/24"],
          "gateway": ["10.10.202.1"]
        },
        {
          "name": "multus-system/vlan204-iot",
          "ips": ["10.10.204.x/24"],
          "gateway": ["10.10.204.1"]
        },
        {
          "name": "multus-system/vlan205-security",
          "ips": ["10.10.205.x/24"],
          "gateway": ["10.10.205.1"]
        }
      ]
```

The pod will get:
- `eth0`: Primary cluster network (Cilium)
- `net1`: First additional network (vlan202-client)
- `net2`: Second additional network (vlan204-iot)
- `net3`: Third additional network (vlan205-security)

## Important: VLAN Interface Configuration

The parent interfaces used by Multus macvlan (`enp6s19/20/21` on all nodes, including the GPU node) must be UP before Multus can create virtual interfaces.

**Durable setup (now baked into infra):**
- Packer template `9001` writes `/etc/netplan/51-vlan-interfaces.yaml` during build (`infra/packer/ubuntu-cloud-init/ubuntu-2404.pkr.hcl`), so every VM cloned from it has VLAN parents up automatically on first boot.
- `infra/ansible/playbooks/k8s-node-fixes.yml` writes the same netplan idempotently for nodes that pre-date the Packer change (or for any node where the file went missing).
- `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml` sets `kube_network_plugin_multus: true` so a fresh kubespray install ships Multus.
- `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-net-cilium.yml` sets `cilium_cni_exclusive: false` so Cilium does not rename Multus's `/etc/cni/net.d/00-multus.conf` to `.cilium_bak`. Without this, Multus is installed but inert — pods never get their secondary interfaces.

**Quick check:**
```bash
# Verify interfaces are UP on all nodes
ansible -i infra/kubespray/inventory/inventory.ini k8s_cluster --private-key /tmp/auto-key -u ubuntu \
  -m shell -a 'ip -br link show enp6s19 enp6s20 enp6s21'
```

If interfaces are DOWN, see runbook: `/docs/runbooks/vlan-interfaces-netplan.md`

## Troubleshooting

### Pod stuck in ContainerCreating
```bash
# Check multus logs
kubectl logs -n kube-system -l app=multus --tail=100

# Check if NAD exists
kubectl get network-attachment-definitions -A
```

### Network not attached
```bash
# Describe pod to see events
kubectl describe pod <pod-name>

# Check annotations
kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations}'
```
