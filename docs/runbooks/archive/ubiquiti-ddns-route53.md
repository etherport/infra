# Ubiquiti Router DDNS Configuration

> ⚠️ **STALE / LEGACY (2026-06-10).** This describes the **Route53** DDNS path.
> The Route53 zone was **deleted 2026-05-27** and authoritative DNS moved to
> Cloudflare. DDNS is migrating to the Cloudflare API (tracked: `outstanding-work.md`
> task #84 / M68 — the writers are currently marked BROKEN in the README DNS table).
> Kept for the router-side config pattern only; do not use the Route53 endpoints below.

Configure your Ubiquiti router (Dream Machine, UDM Pro, etc.) to update Route53 DNS records via the DDNS Lambda endpoint.

## Overview

This setup provides DNS updates for your WAN IP addresses independent of the Kubernetes cluster:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Ubiquiti       │     │  API Gateway    │     │  Route53        │
│  Router         │────►│  + Lambda       │────►│  DNS Records    │
│  (WAN1/WAN2)    │     │                 │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**DNS Records**:
- `wan1.wind.etherport.net` - WAN1 (primary) IP address
- `wan2.wind.etherport.net` - WAN2 (backup) IP address
- `wind.etherport.net` - Active IP (updated by K8s CronJob)

## Prerequisites

1. Deploy the DDNS Lambda infrastructure:
   ```bash
   cd infra/terraform/aws/ddns-lambda
   terraform init
   terraform apply
   ```

2. Note the outputs:
   - `api_endpoint` - The URL for DDNS updates
   - `secret_name` - Name of the Secrets Manager secret containing the API key

3. Retrieve the API key:
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id ddns-api-key \
     --query SecretString \
     --output text \
     --profile homelab | jq -r .api_key
   ```

## Router Configuration

### UniFi Console (Cloud Key, UDM, UDM Pro)

1. Open the UniFi Network application
2. Navigate to **Settings** > **Internet** > **WAN**
3. Select your WAN connection (WAN1 or WAN2)
4. Scroll down to **Dynamic DNS**
5. Enable DDNS and configure:

| Field | Value |
|-------|-------|
| **Service** | `custom` or `dyndns` |
| **Hostname** | `wan1.wind.etherport.net` (or `wan2` for second WAN) |
| **Username** | `unused` (any value works) |
| **Password** | `<API key from Secrets Manager>` |
| **Server** | `<api-id>.execute-api.us-west-2.amazonaws.com/update` |

**Note**: The server URL is from the `api_endpoint` output, without the `https://` prefix.

### EdgeRouter / EdgeOS

SSH into your EdgeRouter and configure:

```bash
configure

# For WAN1
set service dns dynamic interface eth0 service custom-route53 host-name wan1.wind.etherport.net
set service dns dynamic interface eth0 service custom-route53 login unused
set service dns dynamic interface eth0 service custom-route53 password <API_KEY>
set service dns dynamic interface eth0 service custom-route53 protocol dyndns2
set service dns dynamic interface eth0 service custom-route53 server <api-id>.execute-api.us-west-2.amazonaws.com/update

# For WAN2 (if applicable)
set service dns dynamic interface eth1 service custom-route53-wan2 host-name wan2.wind.etherport.net
set service dns dynamic interface eth1 service custom-route53-wan2 login unused
set service dns dynamic interface eth1 service custom-route53-wan2 password <API_KEY>
set service dns dynamic interface eth1 service custom-route53-wan2 protocol dyndns2
set service dns dynamic interface eth1 service custom-route53-wan2 server <api-id>.execute-api.us-west-2.amazonaws.com/update

commit
save
```

### Manual Testing

Test the endpoint with curl:

```bash
# Auto-detect IP (uses source IP)
curl "https://<api-id>.execute-api.us-west-2.amazonaws.com/update?hostname=wan1.wind.etherport.net" \
  -H "x-api-key: <API_KEY>"

# Explicit IP
curl "https://<api-id>.execute-api.us-west-2.amazonaws.com/update?hostname=wan1.wind.etherport.net&myip=1.2.3.4" \
  -H "x-api-key: <API_KEY>"
```

**Expected responses**:
- `good 1.2.3.4` - Updated successfully
- `nochg 1.2.3.4` - No change needed (already set)
- `badauth` - Invalid API key
- `nohost` - Invalid hostname
- `911` - Server error

## Verification

### Check DNS Records

```bash
# Check wan1 record
dig wan1.wind.etherport.net +short

# Check wan2 record
dig wan2.wind.etherport.net +short

# Check main record (updated by K8s CronJob)
dig wind.etherport.net +short
```

### Check Lambda Logs

```bash
aws logs tail /aws/lambda/ddns-updater --follow --profile homelab
```

### Check the record value via Cloudflare API

After the 2026-05-27 Route53 → CF migration the wan1/wan2 records
live in CF (Route53 zone deleted). To inspect via API:

```bash
CF_TOKEN=$(op item get cloudflare-tf-token --field credential --reveal)
CF_ZONE=c45213cbf36fc634b6b75ae9abd49c59  # etherport.net
curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records?type=A&name=wan1.wind.etherport.net" \
  | jq '.result[0].content, .result[0].modified_on'
```

Or just `dig +short wan1.wind.etherport.net @1.1.1.1` for a public
view.

## Troubleshooting

### DDNS Not Updating

1. **Check router logs** for DDNS errors
2. **Verify API key** is correct (no trailing whitespace)
3. **Check Lambda logs** in CloudWatch
4. **Test manually** with curl from outside your network

### "badauth" Response

- API key is incorrect or has extra whitespace
- Retrieve fresh API key from Secrets Manager:
  ```bash
  aws secretsmanager get-secret-value --secret-id ddns-api-key --query SecretString --output text --profile homelab | jq -r .api_key
  ```

### "nohost" Response

- Hostname not in allowed list
- Check spelling: must be exactly `wan1.wind.etherport.net` or `wan2.wind.etherport.net`

### "911" Response

- Server error - check Lambda CloudWatch logs
- Possible IAM permission issues

## Architecture Notes

### DNS Architecture

The `wind.etherport.net` zone is served by **Technitium DNS** (homelab DNS cluster), not Route53 directly:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Router DDNS    │     │  Lambda         │     │  Route53        │
│  Client         │────►│  (API Gateway)  │────►│  (Storage)      │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                                                        ▼
┌─────────────────┐     ┌─────────────────────────────────────────┐
│  DNS Queries    │◄────│  Technitium DNS (wind.etherport.net)    │
│  (internal)     │     │  - K8s pods + fallback VM + AWS         │
└─────────────────┘     └─────────────────────────────────────────┘
```

- **Route53**: Stores authoritative wan1/wan2 records (updated by Lambda)
- **Technitium**: Serves DNS queries for `*.wind.etherport.net`
- **Zone file**: `platform/kubernetes/technitium/zones/wind.etherport.net.yaml`

Technitium zone file contains static wan1/wan2 records that are synced via GitOps. For real-time updates, AWS services (like security group updaters) should query Route53 API directly.

### Why Both Lambda and K8s CronJob?

**Belt and suspenders approach**:
- **K8s CronJob** updates `wind.etherport.net` every minute (existing)
- **Lambda** updates `wan1/wan2.wind.etherport.net` when router detects IP change

If the Kubernetes cluster goes down (hardware failure), the router can still update DNS via Lambda, preventing lockout from AWS resources that use `wan1/wan2.wind.etherport.net` for IP allowlisting.

### Security

- **HTTPS only**: API Gateway enforces TLS
- **API key authentication**: Stored in AWS Secrets Manager
- **Hostname validation**: Lambda only allows wan1/wan2 records
- **Minimal IAM**: Lambda role scoped to specific hosted zone
- **Audit trail**: CloudWatch logs all requests

### Costs

- **Lambda**: Free tier (1M requests/month)
- **API Gateway**: Free tier (1M HTTP API calls/month)
- **Secrets Manager**: ~$0.40/month
- **Total**: ~$0.40/month

## Related Documentation

- [Route53 DDNS K8s CronJob](../../../platform/kubernetes/cloudflare-ddns/)
- [AWS Infrastructure Overview](../../architecture/aws-infrastructure.md)
- [Terraform AWS DDNS Lambda](../../../infra/terraform/aws/ddns-lambda/)
