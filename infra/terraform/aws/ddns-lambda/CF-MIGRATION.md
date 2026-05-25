# ddns-updater Lambda — migration to Cloudflare DNS API

## Why

After cutting `etherport.net` DNS authority from Route53 → Cloudflare (see `docs/runbooks/cloudflare-access-enable.md`), this Lambda's `route53.change_resource_record_sets` calls keep returning 200 OK — Route53 happily accepts writes — but resolvers never query Route53 for `*.etherport.net` anymore, so the updates effectively disappear. WAN1/WAN2 records in CF go stale on next IP change.

## Scope

The Lambda is invoked by the UDM via DynDNS protocol. Currently updates 2 records in Route53:
- `wan1.wind.etherport.net`
- `wan2.wind.etherport.net`

Post-migration: same 2 records, but written to Cloudflare via its DNS API.

## Migration plan

### 1. Create CF API token for the Lambda (scoped)

In dash.cloudflare.com → Profile → API Tokens → Create Custom Token:

| Permission | Scope |
|---|---|
| Zone / DNS / Edit | Specific zone: etherport.net |

Tight scope — Lambda can only edit DNS in the one zone. No other CF perms.

Save to 1P as `Cloudflare DDNS token (lambda)` → field `token`.

### 2. Store token in AWS Secrets Manager

```bash
aws --profile homelab secretsmanager create-secret \
  --name "ddns-lambda/cloudflare-token" \
  --secret-string "{\"token\":\"$(op item get 'Cloudflare DDNS token (lambda)' --fields token --reveal)\"}" \
  --region us-west-2
```

### 3. Update Lambda code

Currently `lambda/handler.py` does:
```python
route53.change_resource_record_sets(
    HostedZoneId=HOSTED_ZONE_ID,
    ChangeBatch={"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {...}}]},
)
```

Replace with CF DNS API:
```python
import urllib.request, json

CF_API = "https://api.cloudflare.com/client/v4"
CF_ZONE_ID = os.environ["CF_ZONE_ID"]
CF_TOKEN = _get_cf_token()  # from Secrets Manager

# Lookup record_id once (could cache via lru_cache):
def find_record_id(hostname):
    url = f"{CF_API}/zones/{CF_ZONE_ID}/dns_records?name={hostname}&type=A"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {CF_TOKEN}"})
    resp = json.loads(urllib.request.urlopen(req).read())
    if not resp["success"] or not resp["result"]:
        raise RuntimeError(f"record {hostname} not found in CF")
    return resp["result"][0]["id"]

# Update:
def update_record(hostname, ip):
    record_id = find_record_id(hostname)
    url = f"{CF_API}/zones/{CF_ZONE_ID}/dns_records/{record_id}"
    body = json.dumps({"type": "A", "name": hostname, "content": ip, "ttl": TTL, "proxied": False}).encode()
    req = urllib.request.Request(url, method="PUT", data=body,
        headers={"Authorization": f"Bearer {CF_TOKEN}", "Content-Type": "application/json"})
    resp = json.loads(urllib.request.urlopen(req).read())
    if not resp["success"]:
        raise RuntimeError(f"CF update failed: {resp.get('errors')}")
```

### 4. Update Lambda TF

In `main.tf`, change env vars:
```hcl
environment {
  variables = {
    ALLOWED_HOSTNAMES   = join(",", var.allowed_hostnames)
    TTL                 = var.ttl
    SECRET_ARN          = aws_secretsmanager_secret.api_key.arn
    # Remove: HOSTED_ZONE_ID
    # Add:
    CF_ZONE_ID          = var.cf_zone_id
    CF_TOKEN_SECRET_ARN = data.aws_secretsmanager_secret.cf_token.arn
  }
}
```

In `iam.tf`:
- Remove the Route53 `route53:ChangeResourceRecordSets` policy statement
- Add Secrets Manager read perm for the new CF token secret

In `variables.tf`:
- Remove `hosted_zone_id`
- Add `cf_zone_id` (sourced from `terraform -chdir=../../cloudflare output -raw zone_id`)

### 5. Apply + verify

```bash
gh workflow run terraform-ddns-lambda.yml -f action=apply

# Trigger an update from the UDM (or invoke lambda directly):
aws --profile homelab lambda invoke --function-name ddns-updater \
  --payload '{"path":"/update","queryStringParameters":{"hostname":"wan1.wind.etherport.net","myip":"47.159.189.5"}}' \
  --cli-binary-format raw-in-base64-out /tmp/out.json && cat /tmp/out.json

# Verify CF record updated:
dig +short wan1.wind.etherport.net @1.1.1.1
```

## Estimated effort

~1-2 hours including code edit, TF tweaks, test invoke.

## Rollback

Revert the Lambda code + TF + redeploy. Route53 perms restored; writes go back to Route53. Recheck UDM DDNS endpoint config (should still be the same Lambda URL — no UDM-side change needed).
