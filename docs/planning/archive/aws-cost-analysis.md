# AWS Cost Analysis & Multi-Region VPN Architecture

**Date:** 2026-04-29
**Purpose:** Analyze current AWS costs and evaluate multi-region VPN architecture for travel

## Current Infrastructure Costs

### EC2 Instances

| Instance | Type | Region | Monthly Cost |
|----------|------|--------|--------------|
| vpn-aws (private-infra_vpn) | t4g.nano | us-west-2 | ~$3.07 |
| dns-aws (private-infra_dns) | t4g.nano | us-west-2 | ~$3.07 |
| **Subtotal** | | | **~$6.14** |

*t4g.nano: $0.0042/hour × 730 hours = $3.07/month*

### Elastic IPs

| EIP | Associated | Monthly Cost |
|-----|------------|--------------|
| vpn-aws EIP | Yes (in-use) | $0.00 |
| dns-aws EIP | Yes (in-use) | $0.00 |

*Note: EIPs are free when attached to running instances*

### EBS Storage

| Volume | Type | Size | IOPS/Throughput | Monthly Cost |
|--------|------|------|-----------------|--------------|
| vpn-aws root | gp3 | 8 GB | 3000/125 | ~$0.68 |
| dns-aws root | gp3 | 8 GB | 3000/125 | ~$0.68 |
| **Subtotal** | | | | **~$1.36** |

*gp3: $0.08/GB/month + baseline IOPS/throughput included*

### Application Load Balancer

| Component | Monthly Cost |
|-----------|--------------|
| ALB hours | ~$16.43 |
| LCU charges | ~$2-5 (varies) |
| **Subtotal** | **~$18-21** |

*ALB: $0.0225/hour × 730 = $16.43 + LCU based on connections/bandwidth*

### Data Transfer (Key Cost Driver)

| Type | Rate | Estimate |
|------|------|----------|
| Data OUT to Internet | $0.09/GB (first 10TB) | Variable |
| Data IN from Internet | Free | $0.00 |
| VPC → Internet (via NAT) | N/A (using IGW) | $0.00 |
| Cross-AZ traffic | $0.01/GB each way | Minimal |

**Estimated Monthly Data Transfer:**

When using `aws-full` VPN for internet egress through vpn-aws:

| Usage Pattern | Data/Month | Cost |
|---------------|------------|------|
| Light (web browsing, email) | 20 GB | $1.80 |
| Moderate (streaming, video calls) | 100 GB | $9.00 |
| Heavy (constant streaming, large downloads) | 300 GB | $27.00 |

### S3 Storage

| Bucket | Storage Class | Approx Size | Monthly Cost |
|--------|---------------|-------------|--------------|
| velero.wind.etherport.net | Standard | ~10 GB | ~$0.23 |
| archive.wind.etherport.net | Deep Archive | ~50 GB | ~$0.05 |
| terraform.wind.etherport.net | Standard | <1 GB | ~$0.02 |
| email-fwd.grahamsmith.net | Standard | <1 GB | ~$0.02 |
| logs.grahamsmith.net | Standard | ~5 GB | ~$0.12 |
| **Subtotal** | | | **~$0.44** |

### Lambda Functions

| Function | Invocations/Month | Duration | Monthly Cost |
|----------|-------------------|----------|--------------|
| dns-restrict-ip | ~8,640 (every 5 min) | 100ms | ~$0.00 |
| ddns-updater | ~100 | 200ms | ~$0.00 |
| email-forward | ~500 | 500ms | ~$0.00 |
| homeassistant-alexa | ~1,000 | 300ms | ~$0.00 |
| **Subtotal** | | | **<$0.10** |

*Lambda free tier: 1M requests + 400,000 GB-seconds/month*

### Route53

| Component | Monthly Cost |
|-----------|--------------|
| Hosted zones (2) | $1.00 |
| Health checks (3 active) | $1.50 |
| DNS queries | ~$0.40 |
| **Subtotal** | **~$2.90** |

### Other Services

| Service | Monthly Cost |
|---------|--------------|
| WAF (ALB WebACL) | ~$6.00 |
| CloudWatch (logs, alarms) | ~$1.00 |
| SNS (notifications) | ~$0.00 |
| ACM (certificates) | $0.00 |
| **Subtotal** | **~$7.00** |

### Current Monthly Total

| Category | Cost |
|----------|------|
| EC2 Instances | $6.14 |
| EBS Storage | $1.36 |
| ALB | ~$19.00 |
| Data Transfer (moderate) | ~$9.00 |
| S3 | ~$0.44 |
| Lambda | ~$0.10 |
| Route53 | ~$2.90 |
| Other (WAF, CW) | ~$7.00 |
| **Total (moderate usage)** | **~$46/month** |

**With heavy VPN usage:** ~$64/month (+$18 for 200GB extra transfer)

---

## Data Transfer Deep Dive

### Current VPN Traffic Pattern

When connected to `aws-full` (WireGuard wg1 with full tunnel):

```
Internet Traffic → vpn-aws → Internet
                     ↓
                  Data OUT charges ($0.09/GB)
```

This is the most expensive path because ALL traffic exits through AWS.

### Optimized Traffic Pattern (Tailscale Exit Node)

Using Tailscale exit node vs. WireGuard full tunnel:

| Exit Node | Use Case | Data Transfer Cost |
|-----------|----------|-------------------|
| vpn-aws (AWS) | Privacy, US geo-location | $0.09/GB |
| k8s-homelab-router | Appear at home | $0.00 (home ISP) |
| vpn-local | Backup home exit | $0.00 (home ISP) |

**Recommendation:** Use homelab exit nodes when possible to avoid AWS data transfer charges.

### VPN Traffic Types

| Traffic Type | Route | Cost |
|--------------|-------|------|
| Homelab services (10.10.x.x) | Tailscale → homelab | $0.00 |
| AWS services (10.10.100.x) | Tailscale → vpn-aws | $0.00 (internal) |
| Internet (full tunnel) | WireGuard wg1 → vpn-aws | $0.09/GB |
| Internet (split tunnel) | Direct | $0.00 |

---

## Multi-Region VPN Architecture

### Why Multi-Region?

When traveling, connecting to a distant VPN (us-west-2 from Europe/Asia) adds:
- **Latency:** +150-300ms RTT
- **Jitter:** Higher on long paths
- **Reliability:** More hops = more failure points

A regional VPN entry point uses the AWS backbone for reliable, low-jitter transit.

### Architecture Options

#### Option 1: On-Demand Regional VPN (Recommended)

Spin up a t4g.nano in the nearest region when traveling, destroy when done.

```
┌─────────────────┐
│  Travel User    │
│  (Tokyo)        │
└────────┬────────┘
         │ ~20ms
         ▼
┌─────────────────┐      AWS Backbone      ┌─────────────────┐
│  vpn-tokyo      │ ─────────────────────► │  vpn-aws        │
│  ap-northeast-1 │      ~100ms            │  us-west-2      │
│  (ON-DEMAND)    │                        │  (PERMANENT)    │
└─────────────────┘                        └────────┬────────┘
                                                    │ wg0
                                                    ▼
                                           ┌─────────────────┐
                                           │  Homelab        │
                                           │  10.10.192.0/19 │
                                           └─────────────────┘
```

**Cost Model:**
| Resource | Monthly Cost (when active) |
|----------|---------------------------|
| t4g.nano | $3.07/month (~$0.10/day) |
| EIP (detached) | $3.65/month |
| EIP (attached) | $0.00 |
| Cross-region data | $0.02/GB |

**Strategy:** Use detached EIP only when instance is down to avoid charges.

#### Option 2: Always-On Regional VPNs

Permanent instances in multiple regions.

| Region | Latency from US-W2 | Monthly Cost |
|--------|-------------------|--------------|
| us-east-1 | ~70ms | $3.07 |
| eu-west-1 | ~140ms | $3.07 |
| ap-northeast-1 | ~120ms | $3.07 |

**Total additional cost:** ~$9.21/month for 3 regions

#### Option 3: Hybrid (One Permanent + On-Demand)

Keep us-east-1 always-on (covers East Coast, EU, Middle East), spin up others as needed.

### VPC Peering Costs

**VPC Peering is FREE to establish.** You only pay for data transfer:

| Route | Cost |
|-------|------|
| Same region, cross-AZ | $0.01/GB each way |
| Cross-region | $0.02/GB each way |

For typical VPN traffic (10-50 GB/month): **$0.20-$1.00/month**

### Recommended Multi-Region Design

```
                           TRAVEL USER
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
         ▼                     ▼                     ▼
   ┌───────────┐        ┌───────────┐        ┌───────────┐
   │ vpn-east  │        │ vpn-eu    │        │ vpn-tokyo │
   │ us-east-1 │        │ eu-west-1 │        │ ap-ne-1   │
   │ ALWAYS-ON │        │ ON-DEMAND │        │ ON-DEMAND │
   └─────┬─────┘        └─────┬─────┘        └─────┬─────┘
         │                    │                    │
         └──────────┬─────────┴────────────────────┘
                    │
                    │ VPC Peering (cross-region)
                    ▼
             ┌───────────┐
             │ vpn-aws   │
             │ us-west-2 │
             │ (HUB)     │
             └─────┬─────┘
                   │ wg0
                   ▼
             ┌───────────┐
             │ Homelab   │
             └───────────┘
```

### Implementation: Terraform Module

Create a reusable module for regional VPN instances:

```hcl
# modules/regional-vpn/main.tf
variable "region" {}
variable "vpc_cidr" {}
variable "hub_vpc_id" {}

resource "aws_vpc" "regional" {
  cidr_block = var.vpc_cidr
  tags = { Name = "vpn-${var.region}" }
}

resource "aws_instance" "vpn" {
  ami           = data.aws_ami.ubuntu_arm.id
  instance_type = "t4g.nano"
  # ... WireGuard config via user_data
}

resource "aws_vpc_peering_connection" "to_hub" {
  vpc_id        = aws_vpc.regional.id
  peer_vpc_id   = var.hub_vpc_id
  peer_region   = "us-west-2"
  auto_accept   = false
}
```

### Cost Comparison Summary

| Scenario | Monthly Cost | Notes |
|----------|-------------|-------|
| Current (us-west-2 only) | ~$46 | Full tunnel through AWS |
| + us-east-1 permanent | ~$49 | Better East Coast/EU access |
| + On-demand regions | ~$46-52 | Pay per travel day (~$0.10/day) |
| Optimized (Tailscale exit) | ~$37 | Reduce data transfer costs |

---

## Recommendations

### Immediate Actions

1. **Monitor Data Transfer:** Check AWS Cost Explorer for actual data transfer costs
   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=2026-04-01,End=2026-04-30 \
     --granularity MONTHLY \
     --metrics "UnblendedCost" \
     --group-by Type=DIMENSION,Key=SERVICE
   ```

2. **Use Tailscale Exit Nodes:** Prefer homelab exit nodes over aws-full WireGuard to avoid $0.09/GB

3. **Track VPN Usage Patterns:** Determine if regional instances are worth the cost based on travel frequency

### Multi-Region Implementation

1. **Phase 1:** Deploy us-east-1 VPN (~$3/month)
   - Covers East Coast US, Europe, Middle East
   - VPC peering to us-west-2
   - Shared WireGuard keys with vpn-aws

2. **Phase 2:** Create Terraform module for on-demand regions
   - `terraform apply -var="region=ap-northeast-1"`
   - `terraform destroy` when done

3. **Phase 3 (Optional):** Lambda automation
   - Spin up regional instance via CloudWatch Events
   - Destroy after 24h of no WireGuard handshakes

---

## Related Documentation

- [VPN Infrastructure Plan](./INFRASTRUCTURE-HARDENING-CHECKLIST.md)
- [AWS Infrastructure](../architecture/aws-infrastructure.md)
- [WireGuard Configuration](../architecture/vpn-wireguard.md)
- [Tailscale Mesh VPN](../architecture/vpn-tailscale.md)
