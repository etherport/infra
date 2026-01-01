# Home Assistant

Home Assistant deployment with multi-VLAN support for device discovery.

## Architecture

- **Container**: Official Home Assistant container (ghcr.io/home-assistant/home-assistant:stable)
- **Storage**: Ceph RBD PVC for config persistence
- **Networking**: Multus CNI for multi-VLAN access
- **Ingress**: Traefik with automatic SSL via Cloudflare

## Network Configuration

Home Assistant has access to multiple VLANs for device discovery:

| Interface | VLAN | Network | IP Address | Purpose |
|-----------|------|---------|------------|---------|
| eth0 | - | Cluster network | Dynamic | Primary cluster connectivity |
| net1 | 202 | 10.10.202.0/24 | 10.10.202.25 | Client devices |
| net2 | 204 | 10.10.204.0/24 | 10.10.204.25 | IoT devices |
| net3 | 205 | 10.10.205.0/24 | 10.10.205.25 | Security devices (cameras, etc.) |

## Prerequisites

### 1. Multus CNI Installation

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.1.0/deployments/multus-daemonset-thick.yml
```

### 2. Node Network Configuration

Each Kubernetes node needs VLAN interfaces configured. See `/docs/kubernetes/node-vlan-setup.md` for details.

Summary:
```bash
# On each node (k8s-w1, k8s-w2, k8s-w3, k8s-gpu1)
# Create systemd-networkd configs for eth1 (VLAN 202), eth2 (VLAN 204), eth3 (VLAN 205)
# Restart systemd-networkd
```

### 3. Terraform Updates

Add additional network adapters to each VM:
```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/terraform/proxmox/k8s-vms
terraform plan
terraform apply
```

This will add 3 additional NICs to each node (VLANs 202, 204, 205).

### 4. Apply Multus NetworkAttachmentDefinitions

```bash
kubectl apply -f /Users/grahamsmith/Projects/homelab-infra/platform/kubernetes/multus/network-attachment-definitions/
```

## Deployment

```bash
# Create namespace
kubectl apply -f namespace.yaml

# Create PVC
kubectl apply -f pvc.yaml

# Deploy Home Assistant
kubectl apply -f deployment.yaml

# Create service
kubectl apply -f service.yaml

# Create ingress
kubectl apply -f ingressroute.yaml
```

## Access

- **External URL**: https://ha.wind.etherport.net (via Traefik with SSL)
- **Direct VLAN access**:
  - 10.10.202.25:8123 (from client VLAN)
  - 10.10.204.25:8123 (from IoT VLAN)
  - 10.10.205.25:8123 (from security VLAN)

## Verification

```bash
# Check pod status
kubectl get pods -n home-automation

# Verify network interfaces
kubectl exec -n home-automation -it <pod-name> -- ip addr

# Should see:
# - eth0: Cluster network (Calico)
# - net1: 10.10.202.25/24
# - net2: 10.10.204.25/24
# - net3: 10.10.205.25/24

# Check logs
kubectl logs -n home-automation -l app=home-assistant -f
```

## Migration from HAOS VM

1. **Backup existing config** from HAOS VM:
   ```bash
   # On HAOS VM
   tar -czf /backup/ha-config-$(date +%Y%m%d).tar.gz /config
   ```

2. **Copy config to PVC**:
   ```bash
   # Create temporary pod with PVC mounted
   kubectl run -n home-automation ha-config-transfer \
     --image=busybox --restart=Never --rm -it \
     --overrides='{"spec":{"containers":[{"name":"ha-config-transfer","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"config","mountPath":"/config"}]}],"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"home-assistant-config"}}]}}'

   # In another terminal, copy files
   kubectl cp -n home-automation ha-config-backup.tar.gz ha-config-transfer:/config/
   kubectl exec -n home-automation ha-config-transfer -- tar -xzf /config/ha-config-backup.tar.gz -C /config/
   ```

3. **Deploy Home Assistant** using the manifests above

4. **Update DNS** to point ha.wind.etherport.net to Traefik

## Troubleshooting

### Pod stuck in ContainerCreating
```bash
# Check multus logs
kubectl logs -n kube-system -l app=multus --tail=100

# Check pod events
kubectl describe pod -n home-automation <pod-name>
```

### Network interface not created
```bash
# Verify NADs exist
kubectl get network-attachment-definitions -n home-automation

# Verify node has VLAN interfaces
ssh <node> ip addr show eth1 eth2 eth3

# Check multus config
kubectl get cm -n kube-system kube-multus-cfg -o yaml
```

### Device discovery not working
```bash
# Verify routes on additional interfaces
kubectl exec -n home-automation <pod-name> -- ip route

# Test connectivity from pod to VLAN device
kubectl exec -n home-automation <pod-name> -- ping -c 3 10.10.204.x
```
