# VLAN Interfaces Not Starting After Reboot

## Problem

After cluster reboot, VLAN network interfaces (`ens19`, `ens20`, `ens21` on worker nodes; `enp6s19/20/21` on GPU node) do not come up automatically, causing Multus networking to fail.

**Symptoms:**
- Home Assistant cannot reach Hue devices (VLAN 204 - IoT)
- Alexa reports "device is not responding"
- Ping to VLAN gateways fails from pods with Multus networks
- `ip link show` shows interfaces as `state DOWN`

## Root Cause

The VLAN parent interfaces are not configured in Netplan, so they remain DOWN after system boot. Multus macvlan CNI requires these parent interfaces to be UP to create virtual interfaces for pods.

## Solution

Configure the interfaces to auto-start in Netplan on all nodes.

### Step 1: Create Netplan Configuration

**For k8s-w1, k8s-w2, k8s-cp1:**

```bash
sudo tee /etc/netplan/51-vlan-interfaces.yaml > /dev/null <<'NETPLAN'
network:
  version: 2
  ethernets:
    ens19:
      optional: true
      dhcp4: no
      dhcp6: no
    ens20:
      optional: true
      dhcp4: no
      dhcp6: no
    ens21:
      optional: true
      dhcp4: no
      dhcp6: no
NETPLAN

sudo chmod 600 /etc/netplan/51-vlan-interfaces.yaml
sudo netplan apply
```

**For k8s-gpu1** (different interface names):

```bash
sudo tee /etc/netplan/51-vlan-interfaces.yaml > /dev/null <<'NETPLAN'
network:
  version: 2
  ethernets:
    enp6s19:
      optional: true
      dhcp4: no
      dhcp6: no
    enp6s20:
      optional: true
      dhcp4: no
      dhcp6: no
    enp6s21:
      optional: true
      dhcp4: no
      dhcp6: no
NETPLAN

sudo chmod 600 /etc/netplan/51-vlan-interfaces.yaml
sudo netplan apply
```

### Step 2: Verify Interfaces Are UP

```bash
# Worker nodes
ip link show ens19 ens20 ens21 | grep "state UP"

# GPU node
ip link show enp6s19 enp6s20 enp6s21 | grep "state UP"
```

### Step 3: Verify Pod Connectivity

```bash
# Test from Home Assistant pod
kubectl exec -n home-automation deployment/home-assistant -- \
  sh -c "ping -c 2 10.10.202.1 && ping -c 2 10.10.204.1 && ping -c 2 10.10.205.1"
```

## Manual Workaround (Temporary)

If you need to bring interfaces up immediately without rebooting:

```bash
# On each node
sudo ip link set ens19 up
sudo ip link set ens20 up
sudo ip link set ens21 up

# Or on GPU node
sudo ip link set enp6s19 up
sudo ip link set enp6s20 up
sudo ip link set enp6s21 up
```

## Prevention

The Netplan configuration ensures interfaces auto-start on boot. Verify after any future reboots that:
1. All nodes have the Netplan config file
2. Interfaces show `state UP` after boot
3. Pod VLAN connectivity works

## Related Issues

- Multus networking fails if parent interfaces are down
- Home Assistant loses access to Hue bridge (VLAN 204)
- Alexa integration fails due to lost Hue connectivity

## References

- Multus Documentation: `/platform/kubernetes/multus/README.md`
- Network Attachment Definitions: `/platform/kubernetes/multus/network-attachment-definitions/`
