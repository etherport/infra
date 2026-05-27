# cloudflare-ddns CronJob — migration to Cloudflare DNS API

## Why

After cutting `etherport.net` DNS authority from Route53 → Cloudflare (see `docs/runbooks/cloudflare-access-enable.md`), this CronJob's `aws route53 change-resource-record-sets` calls keep succeeding but resolvers stop querying Route53 for `*.etherport.net`. The `wind.etherport.net` "active WAN" record goes stale on next failover.

Also: the CronJob currently uses `wan1.wind.etherport.net` + `wan2.wind.etherport.net` DNS lookups to determine which WAN's IP to write. Once CF is authoritative, those lookups return the CF-managed values (kept fresh by the ddns-updater Lambda which we're also migrating).

## Scope

Cron runs every minute. Updates 1 record:
- `wind.etherport.net` ← whichever of (wan1, wan2) matches current public egress

Post-migration: same logic, but `aws cli` → `curl` against CF API.

## Migration plan

### 1. Reuse the CF token from the ddns-updater Lambda migration

Same `Cloudflare DDNS token (lambda)` 1P item works — `Zone / DNS / Edit` on etherport.net zone covers both writers.

### 2. Update the script

`image/scripts/update-cf-dns.sh` currently uses `aws cli`. Rewrite the update block to use `curl` against `https://api.cloudflare.com/client/v4`:

```bash
# Lookup record_id (cache for the script's lifetime):
record_id() {
  local hostname=$1
  curl -s -H "Authorization: Bearer $CF_TOKEN" \
    "$CF_API/zones/$CF_ZONE_ID/dns_records?name=$hostname&type=A" \
    | jq -r '.result[0].id'
}

# Update record (replace the route53 change-resource-record-sets call):
update_record() {
  local hostname=$1
  local ip=$2
  local rid=$(record_id "$hostname")
  curl -s -X PUT -H "Authorization: Bearer $CF_TOKEN" \
       -H "Content-Type: application/json" \
       "$CF_API/zones/$CF_ZONE_ID/dns_records/$rid" \
       -d "{\"type\":\"A\",\"name\":\"$hostname\",\"content\":\"$ip\",\"ttl\":$TTL,\"proxied\":false}" \
    | jq -e '.success == true' >/dev/null
}
```

### 3. Update the Dockerfile

Currently bundles aws-cli; can drop it after rewrite (saves image size). Curl + jq are already in alpine base.

### 4. Update k8s manifest

`base/cronjob.yaml` env vars — replace AWS creds with CF token from a new SOPS secret:

```yaml
env:
  - name: CF_API
    value: "https://api.cloudflare.com/client/v4"
  - name: CF_ZONE_ID
    value: "<from terraform output>"
  - name: CF_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-ddns-token
        key: token
  # Keep: IP_WAN1_DNS, IP_WAN2_DNS, IP_DNS_SOURCE, IP_SERVICE_URL, TTL
  # Remove: AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
  #         HOSTED_ZONES, RECORD_NAMES (or restructure to single hostname)
```

Create `base/01-cf-token.sops.yaml` analogous to the cloudflared token secret.

### 5. Update IAM removal

`base/rbac.yaml` only manages a k8s SA — no AWS IAM in cluster. The actual AWS access key was set via the SOPS secret. Replace the SOPS secret entirely.

For the AWS IAM user that backed those creds (if a dedicated one exists), remove the route53 policy after migration confirmed.

### 6. Apply + verify

```bash
git add platform/kubernetes/cloudflare-ddns/
git commit -m "cloudflare-ddns: migrate from Route53 to Cloudflare DNS API"
git push
# Flux reconciles, next cron tick uses CF.

# Verify in logs:
kubectl logs -n cloudflare-ddns -l app=cloudflare-ddns --tail=20 | grep -E "Updated|Skipped"

# Verify the record reflects in CF:
dig +short wind.etherport.net @1.1.1.1
```

## Rename consideration

Once migrated, the namespace + workload name `cloudflare-ddns` is misleading. Rename to `cloudflare-ddns` for clarity. Bundled with the migration commit or done as a follow-up.

## Estimated effort

~1 hour including script edit, secret rotation, test cycle.

## Rollback

Revert script + manifest + redeploy. Restore SOPS secret with AWS creds. CronJob resumes writing to Route53. Resolvers still see CF answers — so updates won't actually propagate, but writes succeed.

If full rollback needed (return DNS authority to Route53 too): NS-flip back at registrar, then this CronJob's Route53 writes start propagating again.
