# ddns-updater Lambda — Route53 → Cloudflare cutover

The ddns-updater Lambda was originally a DynDNS-compatible endpoint
that wrote WAN1/WAN2 IP changes from the UDM into the etherport.net
Route53 zone. After 2026-05-27's DNS migration deleted that Route53
zone, the Lambda was broken (and dormant — no recent UDM invocations).

This runbook covers the cutover to Cloudflare.

## What's already in code

- `infra/terraform/aws/ddns-lambda/lambda/handler.py` — rewritten to
  use the CF REST API (`api.cloudflare.com/client/v4`) instead of
  boto3 Route53. Reads BOTH `api_key` (existing — router auth) AND
  `cf_api_token` (new — CF API write auth) from the same Secrets
  Manager secret.
- `infra/terraform/aws/ddns-lambda/variables.tf` — `hosted_zone_id`
  removed, replaced with `cf_zone_id` (defaults to the etherport.net
  CF zone).
- `infra/terraform/aws/ddns-lambda/main.tf` — env var `HOSTED_ZONE_ID`
  replaced with `CF_ZONE_ID`.

## User-side cutover (one-time, ~3 min)

### 1. Get a Cloudflare API token

Reuse the existing `cloudflare-tf-token` (already has Zone:DNS:Edit
on etherport.net) OR create a dedicated one. New tokens go to
1Password as `cloudflare-ddns-updater-token` (suggested naming).

### 2. Update Secrets Manager payload

The Lambda's Secrets Manager secret ARN is set as `SECRET_ARN` env
var. Currently it holds `{"api_key": "..."}`. Extend it:

```bash
# Pull the current secret + add the CF token
EXISTING=$(aws secretsmanager get-secret-value \
  --secret-id ddns-api-key-yS5lFH \
  --query SecretString --output text)

CF_TOKEN=$(op item get cloudflare-tf-token --field credential --reveal)

NEW=$(echo "$EXISTING" | jq --arg t "$CF_TOKEN" '. + {cf_api_token: $t}')

aws secretsmanager put-secret-value \
  --secret-id ddns-api-key-yS5lFH \
  --secret-string "$NEW"
```

### 3. Deploy the new Lambda code

```bash
# Dispatch the workflow (re-zips handler.py and pushes to Lambda)
gh workflow run terraform-ddns-lambda.yml -f action=apply
```

### 4. Validate

Tail the Lambda logs while triggering a manual update:

```bash
aws logs tail /aws/lambda/ddns-updater --region us-west-2 --follow
```

In another shell, trigger the Lambda directly using its Function URL +
the existing router shared-secret `api_key`:

```bash
LAMBDA_URL=$(aws lambda get-function-url-config \
  --region us-west-2 --function-name ddns-updater \
  --query FunctionUrl --output text)

API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id ddns-api-key-yS5lFH \
  --query SecretString --output text | jq -r .api_key)

# Update wan1 with the current WAN1 public IP from CF (no-op test)
curl -s -H "x-api-key: $API_KEY" \
  "${LAMBDA_URL}update?hostname=wan1.wind.etherport.net&myip=47.159.189.5"
# Expected: "nochg 47.159.189.5"

# Update wan1 with a fake IP — should return "good <ip>" and the CF
# record actually updates. Verify with:
curl -s -H "x-api-key: $API_KEY" \
  "${LAMBDA_URL}update?hostname=wan1.wind.etherport.net&myip=192.0.2.99"
dig +short wan1.wind.etherport.net @1.1.1.1
# Then revert:
curl -s -H "x-api-key: $API_KEY" \
  "${LAMBDA_URL}update?hostname=wan1.wind.etherport.net&myip=47.159.189.5"
```

### 5. Verify the UDM is still wired to call this Lambda

UDM Network → Settings → Internet → WAN1 → Dynamic DNS:
- Service: Custom
- Server: `<lambda function URL host>`
- Username: anything (ignored — Basic Auth password is what we check)
- Password: the `api_key` value from Secrets Manager
- Hostname: `wan1.wind.etherport.net`

Same for WAN2 with `wan2.wind.etherport.net`.

If the UDM-side config still has the old endpoint or wrong creds,
update accordingly. The Lambda Function URL itself didn't change.

## After cutover

- Drop the `route53` IAM policy from `infra/terraform/aws/ddns-lambda/`
  (no longer needed; Lambda only writes via HTTPS to CF).
- Drop the `route53` env var fallback from `main.tf`'s
  `depends_on` list.
- Update `docs/setup/network/ubiquiti-ddns.md` to reference the
  CF-side path.
- Verify: next WAN IP change actually flows from UDM → Lambda → CF
  record updated. CF dashboard will show the record's "Updated"
  timestamp.

## Rollback

If something breaks: revert handler.py to git history. The Lambda
falls back to the old Route53 code, which will fail (zone deleted)
but won't make anything worse than current state.
