# Kubernetes Node VLAN Interface Configuration

## Overview

All Kubernetes nodes have been configured with 4 network interfaces for multi-VLAN support:
- **eth0** (VLAN 201): Management network - 10.10.201.0/24
- **eth1** (VLAN 202): Client network - 10.10.202.0/24
- **eth2** (VLAN 204): IoT devices network - 10.10.204.0/24
- **eth3** (VLAN 205): Security network - 10.10.205.0/24

## Node IP Assignments

| Node | eth0 (201) | eth1 (202) | eth2 (204) | eth3 (205) |
|------|------------|------------|------------|------------|
| k8s-cp1 | 10.10.201.50 | 10.10.202.50 | 10.10.204.50 | 10.10.205.50 |
| k8s-w1  | 10.10.201.51 | 10.10.202.51 | 10.10.204.51 | 10.10.205.51 |
| k8s-w2  | 10.10.201.52 | 10.10.202.52 | 10.10.204.52 | 10.10.205.52 |
| k8s-gpu1| 10.10.201.53 | 10.10.202.53 | 10.10.204.53 | 10.10.205.53 |

## Configuration

The additional interfaces (eth1-eth3) are configured via systemd-networkd.

### Setup on Each Node

Run these commands on **each node** (k8s-cp1, k8s-w1, k8s-w2, k8s-gpu1):

```bash
# Determine the node's last octet from its hostname
NODE_IP_LAST_OCTET=$(hostname | sed 's/k8s-cp/5/; s/k8s-w//; s/k8s-gpu/5/' | sed 's/1/1/; s/2/2/; s/3/3/')

# For cp1: 50, w1: 51, w2: 52, gpu1: 53
case $(hostname) in
  k8s-cp1)  NODE_IP_LAST_OCTET=50 ;;
  k8s-w1)   NODE_IP_LAST_OCTET=51 ;;
  k8s-w2)   NODE_IP_LAST_OCTET=52 ;;
  k8s-gpu1) NODE_IP_LAST_OCTET=53 ;;
esac

# Create systemd-networkd config for eth1 (VLAN 202 - Client)
sudo tee /etc/systemd/network/10-eth1.network <<EOF
[Match]
Name=eth1

[Network]
Address=10.10.202.${NODE_IP_LAST_OCTET}/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# Create systemd-networkd config for eth2 (VLAN 204 - IoT)
sudo tee /etc/systemd/network/10-eth2.network <<EOF
[Match]
Name=eth2

[Network]
Address=10.10.204.${NODE_IP_LAST_OCTET}/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# Create systemd-networkd config for eth3 (VLAN 205 - Security)
sudo tee /etc/systemd/network/10-eth3.network <<EOF
[Match]
Name=eth3

[Network]
Address=10.10.205.${NODE_IP_LAST_OCTET}/24
ConfigureWithoutCarrier=yes

[Link]
RequiredForOnline=no
EOF

# Enable and restart systemd-networkd
sudo systemctl enable systemd-networkd
sudo systemctl restart systemd-networkd

# Verify interfaces are up
ip -br addr show eth1 eth2 eth3
```

**Expected output:**
```
eth1             UP             10.10.202.5X/24
eth2             UP             10.10.204.5X/24
eth3             UP             10.10.205.5X/24
```

## Terraform Changes

The additional network interfaces were added in:
- **File**: `infra/terraform/proxmox/k8s-vms/main.tf`
- **Commit**: Applied with `terraform apply`

Each VM now has 4 `network_device` blocks:
1. VLAN 201 (management) - configured by cloud-init
2. VLAN 202 (client) - configured by systemd-networkd
3. VLAN 204 (IoT) - configured by systemd-networkd
4. VLAN 205 (security) - configured by systemd-networkd

## Verification

On any node:
```bash
# Check all interfaces
ip -br addr show | grep -E 'eth[0-3]'

# Ping Home Assistant on each VLAN (after HA is deployed)
ping -c 1 10.10.201.25  # Management
ping -c 1 10.10.202.25  # Client
ping -c 1 10.10.204.25  # IoT
ping -c 1 10.10.205.25  # Security
```

## Troubleshooting

### Interface not showing UP
```bash
# Check systemd-networkd status
sudo systemctl status systemd-networkd

# Check interface state
ip link show eth1

# Manually bring up interface
sudo ip link set eth1 up
```

### Configuration not applied
```bash
# Check networkd configuration
networkctl status eth1

# Restart networkd
sudo systemctl restart systemd-networkd
```

### Verify Proxmox side
In Proxmox UI → VM → Hardware, you should see:
- net0: vmbr0, tag=201
- net1: vmbr0, tag=202
- net2: vmbr0, tag=204
- net3: vmbr0, tag=205
