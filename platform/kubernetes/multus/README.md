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
cd infra/ansible
ansible-playbook -i inventory/wind/hosts.yml kubespray/cluster.yml --tags network
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

GPU Node Variants (k8s-gpu1 uses different interface naming):
- `vlan202-client-gpu`: Uses `enp6s19` interface
- `vlan204-iot-gpu`: Uses `enp6s20` interface
- `vlan205-security-gpu`: Uses `enp6s21` interface

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

The parent interfaces used by Multus macvlan (`ens19/20/21` on worker nodes, `enp6s19/20/21` on GPU node) must be UP before Multus can create virtual interfaces.

**Issue:** After cluster reboot, these interfaces may be DOWN, causing all VLAN networking to fail.

**Solution:** Configure interfaces in Netplan on all nodes. See runbook: `/docs/runbooks/vlan-interfaces-netplan.md`

**Quick check:**
```bash
# Verify interfaces are UP
ssh graham@k8s-w1.wind.etherport.net "ip link show ens19 ens20 ens21 | grep UP"
```

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
