# Regional VPN Deployment Runbook — ARCHIVED (tooling DELETED 2026-07-01)

> **⚠️ ARCHIVED — tooling DELETED 2026-07-01 (M110 "travel-tooling cleanup").** No
> regional/travel VPN had been deployed since the Mumbai teardown (2026-05-23); the
> permanent us-east-1 spoke was **decommissioned 2026-07-01**, and the tooling
> (`infra/terraform/aws-regional-vpn/`, `infra/terraform/modules/regional-vpn/`,
> `terraform-regional-vpn.yml`, `platform/wireguard/regional-peers.yaml`) was **removed
> from the repo** the same day (both TF workspaces held 0 resources; S3 states deleted).
> Tailscale (exit nodes on the edge box / homelab) covers remote/travel access — see
> [`../../architecture/vpn-tailscale.md`](../../architecture/vpn-tailscale.md). This doc
> is kept as the historical procedure; resurrecting the capability means **restoring the
> deleted paths from git history** (the commit referenced in session-log 2026-07-01) and
> re-creating the tfstate keys.

Deploy temporary WireGuard VPN endpoints in AWS regions closest to your travel location.

**IMPORTANT:** Regional VPNs are **temporary infrastructure**. Destroy when done traveling to stop billing.

## Current Deployment Status

**No regional VPN is currently deployed** (`platform/wireguard/regional-peers.yaml`
`status: destroyed`). Reference assignments for the next deploy:

| Region | Tunnel IP | VPC CIDR | Status |
|--------|-----------|----------|--------|
| ap-south-1 (Mumbai) | 10.255.255.3 | 10.10.112.0/24 | Not deployed |
| me-south-1 (Bahrain) | 10.255.255.4 | 10.10.116.0/24 | Not deployed |
| eu-west-1 (Ireland) | 10.255.255.5 | 10.10.120.0/24 | Not deployed |

**Note:** Check the [AWS Health Dashboard](https://health.aws.amazon.com/) for your target region before deploying.

## Quick Reference: Closest Regions

| Location | AWS Region | Region Code | Latency | Status |
|----------|------------|-------------|---------|--------|
| India / Gulf | **ap-south-1** (Mumbai) | `mumbai` | ~10-20ms | Available |
| Abu Dhabi / Dubai | me-central-1 (UAE) | `uae` | ~5ms | Available |
| Bahrain / Gulf | me-south-1 (Bahrain) | `bahrain` | ~5ms | Available |
| Europe (West) | eu-west-1 (Ireland) | `ireland` | ~20ms | Available |
| Europe (Central) | eu-central-1 (Frankfurt) | `frankfurt` | ~15ms | Available |
| Asia (East) | ap-northeast-1 (Tokyo) | `tokyo` | ~30ms | Available |
| Asia (Southeast) | ap-southeast-1 (Singapore) | `singapore` | ~20ms | Available |
| US East Coast | us-east-1 (Virginia) | `virginia` | ~10ms | Available |

## Method 1: GitHub Actions (Recommended)

The easiest way to deploy regional VPN infrastructure. No local tools required beyond a web browser.

### Prerequisites

1. The workflow assumes the `gh-actions-terraform` IAM role via GitHub OIDC (H29) —
   there are no static AWS key secrets. Repository secrets required:
   - `SOPS_AGE_KEY` - Age private key for secret decryption
   - `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ZONE_ID` - for the post-apply DNS update

### Deploy a New Region

1. Go to **Actions** > **Regional VPN Terraform** > **Run workflow**
2. Fill in parameters:
   - **Action**: `apply`
   - **Workspace**: Region short name (e.g., `mumbai`)
   - **Region**: AWS region code (e.g., `ap-south-1`)
   - **Region short**: Short name (e.g., `mumbai`)
   - **VPC CIDR**: Unique /24 block (e.g., `10.10.112.0/24`)
   - **Tunnel IP**: Next available (e.g., `10.255.255.3`)
3. Click **Run workflow**

The workflow will:
- Generate WireGuard keys (if new deployment)
- Deploy VPC, EC2 instance, security groups
- Configure WireGuard on the instance
- Update `vpn-travel.etherport.net` DNS to point to new IP
- Commit `platform/wireguard/regional-peers.yaml` with peer config
- Output summary with connection details

### Update Homelab Peers (Manual Step)

After apply, you must add the new peer to homelab WireGuard:

1. Check the workflow run summary for the peer config
2. Edit `platform/kubernetes/wireguard/03-deployment.yaml`
3. Add the new `[Peer]` block to the wg0 configuration
4. Commit and push (Flux will sync to cluster)
5. Run Ansible to update vpn-local:
   ```bash
   cd infra/ansible
   ansible-playbook -i inventory/wind/ playbooks/wireguard.yml --limit vpn-local
   ```

### Configure Your Client

The client config uses the `vpn-travel.etherport.net` DNS name, so it automatically points to the current regional VPN:

```ini
# travel-full.conf (stored in 1Password)
[Interface]
PrivateKey = <your private key>
Address = 10.254.0.10/32
DNS = 10.10.100.5, 10.10.201.5, 10.10.201.6
# IMPORTANT: do NOT add public resolvers (1.1.1.1 etc.) here.
# macOS getaddrinfo() races all pushed resolvers in parallel; the
# public resolver wins and `*.wind.etherport.net` resolves to the
# AWS ALB public IP instead of the internal MetalLB VIP. Caught
# 2026-05-18 — see platform/wireguard/clients/graham-tcp.conf.template.

[Peer]
PublicKey = Aav0cNl4osaEEISQLyKLt88foAPwdVYaeTuyLF/PNTo=
Endpoint = vpn-travel.etherport.net:51821
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

This single config works for any region - just update the DNS when switching regions.

### Destroy When Done

1. Go to **Actions** > **Regional VPN Terraform** > **Run workflow**
2. Select **Action**: `destroy`
3. Use the same parameters as apply
4. Run workflow

The workflow will:
- Destroy all AWS resources
- Clear `regional-peers.yaml`
- Commit the change

**Don't forget:** Remove the peer from `03-deployment.yaml` and re-run Ansible.

### Workflow Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    GitHub Actions Workflow                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  User triggers workflow via GitHub UI                            │
│            │                                                      │
│            ▼                                                      │
│  ┌─────────────────┐                                             │
│  │ Setup Environment│                                             │
│  │ • Terraform      │                                             │
│  │ • AWS creds      │                                             │
│  │ • SOPS/age key   │                                             │
│  └────────┬────────┘                                             │
│           │                                                       │
│           ▼                                                       │
│  ┌─────────────────┐    ┌─────────────────┐                      │
│  │ Terraform Init  │───▶│ S3 Backend      │                      │
│  │ (profile="")    │    │ terraform.wind..│                      │
│  └────────┬────────┘    └─────────────────┘                      │
│           │                                                       │
│           ▼                                                       │
│  ┌─────────────────┐                                             │
│  │ Select Workspace│  (e.g., "mumbai")                           │
│  └────────┬────────┘                                             │
│           │                                                       │
│           ▼                                                       │
│  ┌─────────────────────────────────────────┐                     │
│  │ Execute Action                          │                     │
│  │ • plan:    Show changes                 │                     │
│  │ • apply:   Deploy + update DNS/config   │                     │
│  │ • destroy: Teardown + clear config      │                     │
│  └────────┬────────────────────────────────┘                     │
│           │                                                       │
│           ▼                                                       │
│  ┌─────────────────┐    ┌─────────────────┐                      │
│  │ Post-Actions    │───▶│ Route53 DNS     │                      │
│  │ (apply only)    │    │ vpn-travel...   │                      │
│  │                 │    └─────────────────┘                      │
│  │                 │    ┌─────────────────┐                      │
│  │                 │───▶│ Git commit      │                      │
│  │                 │    │ regional-peers  │                      │
│  └─────────────────┘    └─────────────────┘                      │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

## Method 2: Local Terraform

For when you need more control or GitHub Actions isn't available.

### Prerequisites

1. AWS CLI configured with `homelab` profile
2. SOPS age key at `~/.config/sops/age/keys.txt`
3. Terraform installed
4. WireGuard tools (`wg` command)

### Deploy a New Region

```bash
cd infra/terraform/aws-regional-vpn   # repo-relative

# 1. Generate new WireGuard keys for wg0
wg genkey | tee /tmp/wg0.key | wg pubkey > /tmp/wg0.pub

# 2. Initialize terraform
terraform init

# 3. Deploy (example: Mumbai)
terraform apply \
  -var="region=ap-south-1" \
  -var="region_short=mumbai" \
  -var="vpc_cidr=10.10.112.0/24" \
  -var="wg0_tunnel_ip=10.255.255.3" \
  -var="wg0_private_key=$(cat /tmp/wg0.key)" \
  -var="wg0_public_key=$(cat /tmp/wg0.pub)"

# 4. Get outputs
terraform output vpn_public_ip
terraform output homelab_peer_config  # Add to K8s deployment
terraform output client_config        # Your device config

# 5. Update DNS manually (Cloudflare — migrated from Route53 2026-05-27)
CF_TOKEN=$(op item get cloudflare-tf-token --field credential --reveal)
CF_ZONE=c45213cbf36fc634b6b75ae9abd49c59  # etherport.net
VPN_IP=<the EIP from terraform output vpn_public_ip>
NAME=vpn-travel.etherport.net

RID=$(curl -fsS -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=$NAME" \
  | jq -r '.result[0].id // empty')

BODY=$(jq -n --arg name "$NAME" --arg ip "$VPN_IP" \
  '{type:"A", name:$name, content:$ip, ttl:300, proxied:false, comment:"Managed by terraform-regional-vpn workflow"}')

if [ -n "$RID" ]; then
  curl -fsS -X PUT -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records/$RID" \
    -d "$BODY" | jq -e '.success'
else
  curl -fsS -X POST -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records" \
    -d "$BODY" | jq -e '.success'
fi
```

This is the same snippet baked into `.github/workflows/terraform-regional-vpn.yml`
— normally you don't run it manually; the workflow does it post-apply.

### Destroy

```bash
terraform destroy \
  -var="region=ap-south-1" \
  -var="region_short=mumbai" \
  -var="vpc_cidr=10.10.112.0/24" \
  -var="wg0_tunnel_ip=10.255.255.3" \
  -var="wg0_private_key=dummy" \
  -var="wg0_public_key=dummy"
```

## Tunnel IP Assignments

| IP | Region | Notes |
|----|--------|-------|
| 10.255.255.1 | vpn-aws (us-west-2) | Primary, permanent |
| 10.255.255.2 | Homelab K8s | Primary local endpoint |
| 10.255.255.3 | Mumbai (ap-south-1) | Reserved |
| 10.255.255.4 | Bahrain (me-south-1) | Reserved |
| 10.255.255.5 | Ireland (eu-west-1) | Reserved |
| 10.255.255.6 | Frankfurt (eu-central-1) | Reserved |

## DNS Configuration

### vpn-travel.etherport.net

Single DNS entry that always points to the current travel VPN:

- **Record Type**: A
- **TTL**: 300 (5 minutes)
- **Value**: Current regional VPN public IP

This allows a single client config to work across all regions.

### Client Config DNS Options

| DNS Setting | Use Case |
|-------------|----------|
| `10.10.100.5, 10.10.201.5, 10.10.201.6` | **Recommended** — dns-aws primary, homelab fallback. NO public resolvers (see below). |
| `10.10.201.5, 10.10.201.6` | Homelab only (breaks if tunnel down) |
| `1.1.1.1, 8.8.8.8` | Public only (no internal names) — NOT recommended |

> **Do not mix internal + public resolvers** (e.g., `10.10.100.5, 1.1.1.1`).
> macOS `getaddrinfo()` races resolvers in parallel; the public resolver
> wins for `*.wind.etherport.net` because it returns the AWS ALB IP
> faster than the internal one returns the MetalLB VIP, splitting DNS
> the wrong way. Caught 2026-05-18 after the SDN migration.

## Cost Summary

| Resource | Hourly | Daily | Monthly |
|----------|--------|-------|---------|
| t4g.nano | $0.0042 | $0.10 | $3.07 |
| Public IP (attached) | $0.00 | $0.00 | $0.00 |
| Data transfer | $0.09/GB | varies | varies |

**Total for 1-week trip:** ~$0.70 + data transfer

**Regional pricing note:** t4g.nano is ~$0.003/hr in Bahrain (25% cheaper than Mumbai) when available.

## Verification

### Test Connection

```bash
# Activate tunnel
wg-quick up travel-full

# Test homelab connectivity
ping 10.10.201.50

# Verify exit IP is regional
curl https://api.ipify.org
# Should show regional VPN IP, not home IP

# Test internal DNS
dig ha.wind.etherport.net @10.10.100.5
```

### Check VPN Server

```bash
# SSH to VPN instance
ssh -i ~/.ssh/gs-ec2.pem ubuntu@<public-ip>

# Check WireGuard status
sudo wg show

# Check homelab tunnel
ping 10.255.255.2  # K8s WireGuard endpoint
ping 10.10.201.50  # k8s-cp1
```

## Troubleshooting

### Workflow Fails on Terraform Init

**Error:** `failed to get shared config profile, homelab`

**Cause:** Backend or provider trying to use local AWS profile

**Fix:** Ensure workflow uses `-backend-config="profile="` and `-var="aws_profile="`

### WireGuard Tunnel Won't Establish

1. Check security group allows UDP 51820-51821
2. Verify keys match between peers
3. Check instance has public IP
4. Verify cloud-init completed: `sudo cloud-init status`

### No Internet Through Tunnel

```bash
# On VPN server, check NAT
sudo iptables -t nat -L -n -v

# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # Should be 1

# Check routing
ip route
```

### Region API Timeout

**Error:** `Connect timeout on endpoint URL: "https://ec2.me-south-1.amazonaws.com/"`

**Cause:** AWS region is offline or unreachable

**Fix:** Check [AWS Health Dashboard](https://health.aws.amazon.com/) and choose different region

## See Also

- [GitHub Actions Documentation](../../setup/github-actions/README.md)
- [AWS Cost Analysis](../../planning/archive/aws-cost-analysis.md)
- [VPN Split Tunnel Guide](../../guides/vpn-split-tunnel.md)
- [WireGuard Architecture](../../architecture/vpn-wireguard.md)
