# Regional VPN Deployment Runbook

Deploy temporary WireGuard VPN endpoints in AWS regions closest to your travel location.

## Quick Reference: Closest Regions

| Location | AWS Region | Region Code | Latency |
|----------|------------|-------------|---------|
| Abu Dhabi / Dubai / Gulf | **me-south-1** (Bahrain) | `bah` | ~5-10ms |
| Europe (West) | eu-west-1 (Ireland) | `ire` | ~20ms |
| Europe (Central) | eu-central-1 (Frankfurt) | `fra` | ~15ms |
| Asia (East) | ap-northeast-1 (Tokyo) | `tyo` | ~30ms |
| Asia (Southeast) | ap-southeast-1 (Singapore) | `sgp` | ~20ms |
| US East Coast | us-east-1 (Virginia) | `use` | ~10ms |

## Prerequisites

1. AWS CLI configured with `homelab` profile
2. SOPS age key available (`~/.config/sops/age/keys.txt`)
3. Terraform installed
4. WireGuard client on your device

## Method 1: Terraform (Recommended)

### Deploy

```bash
cd ~/Projects/homelab-infra/infra/terraform/aws-regional-vpn

# Initialize (first time only)
terraform init

# Deploy to Bahrain (closest to UAE)
terraform apply -var="region=me-south-1" -var="region_short=bah"

# Get the public IP
terraform output vpn_public_ip
```

### Configure Client

Update your WireGuard config with the new endpoint:

```ini
# ~/.wireguard/travel-bah.conf
[Interface]
PrivateKey = <your private key from 1Password>
Address = 10.254.0.10/32
DNS = 10.10.201.5, 10.10.201.6

[Peer]
# vpn-bah (Bahrain)
PublicKey = <vpn-aws public key - same as existing>
Endpoint = <terraform output vpn_public_ip>:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### Verify Connection

```bash
# SSH to verify instance is running
ssh -i ~/.ssh/gs-ec2.pem ubuntu@<public-ip>

# Check WireGuard status
sudo wg show

# On your device, activate the tunnel and test
ping 10.10.201.50  # Homelab
curl https://api.ipify.org  # Should show Bahrain IP
```

### Destroy (Stop Billing!)

```bash
terraform destroy -var="region=me-south-1" -var="region_short=bah"
```

## Method 2: Manual AWS CLI (Faster for One-Off)

### 1. Launch Instance

```bash
# Set region
export AWS_REGION=me-south-1
export AWS_PROFILE=homelab

# Get latest Ubuntu ARM AMI
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

# Create security group (if not exists)
SG_ID=$(aws ec2 create-security-group \
  --group-name vpn-travel \
  --description "Travel VPN" \
  --output text --query 'GroupId' 2>/dev/null || \
  aws ec2 describe-security-groups \
    --group-names vpn-travel \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

# Allow WireGuard and SSH
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol udp --port 51820-51821 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

# Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t4g.nano \
  --key-name GS-EC2 \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=vpn-travel}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance: $INSTANCE_ID"

# Wait for public IP
sleep 30
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
```

### 2. Configure WireGuard via SSH

```bash
# Get keys from SOPS
cd ~/Projects/homelab-infra
WG_PRIVATE=$(sops -d platform/wireguard/servers/vpn-aws.sops.yaml | yq '.stringData.wg0_private_key')
HOMELAB_PUBLIC=$(sops -d platform/wireguard/servers/vpn-local.sops.yaml | yq '.stringData.wg0_public_key')
CLIENT_PUBLIC=$(sops -d platform/wireguard/clients/graham.sops.yaml | yq '.stringData.public_key')

# SSH and configure
ssh -i ~/.ssh/gs-ec2.pem ubuntu@$PUBLIC_IP << 'ENDSSH'
sudo apt-get update && sudo apt-get install -y wireguard

# Enable forwarding
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-wg.conf
sudo sysctl -p /etc/sysctl.d/99-wg.conf

# Create wg1 config for remote access
sudo tee /etc/wireguard/wg1.conf << 'EOF'
[Interface]
Address = 10.254.0.1/24
ListenPort = 51821
PrivateKey = ${WG_PRIVATE}
PostUp = iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ens5 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC}
AllowedIPs = 10.254.0.10/32
EOF

sudo chmod 600 /etc/wireguard/wg1.conf
sudo systemctl enable --now wg-quick@wg1
sudo wg show
ENDSSH
```

### 3. Terminate When Done

```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
```

## Cost Summary

| Resource | Hourly | Daily | Monthly |
|----------|--------|-------|---------|
| t4g.nano | $0.0042 | $0.10 | $3.07 |
| Public IP (attached) | $0.00 | $0.00 | $0.00 |
| Data transfer | $0.09/GB | varies | varies |

**Total for 1-week trip:** ~$0.70 + data transfer

## Troubleshooting

### Instance Not Reachable

```bash
# Check security group
aws ec2 describe-security-groups --group-ids $SG_ID

# Check instance status
aws ec2 describe-instance-status --instance-ids $INSTANCE_ID
```

### WireGuard Tunnel Not Establishing

```bash
# SSH to instance and check
ssh ubuntu@$PUBLIC_IP
sudo wg show
sudo journalctl -u wg-quick@wg1 -f
```

### No Internet Through Tunnel

```bash
# Check NAT rules on VPN server
sudo iptables -t nat -L -n -v

# Check routing
ip route
```

## See Also

- [AWS Cost Analysis](../planning/aws-cost-analysis.md)
- [VPN Split Tunnel Guide](../guides/vpn-split-tunnel.md)
- [WireGuard Architecture](../architecture/vpn-wireguard.md)
