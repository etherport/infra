# cloudflare-ddns CronJob — Route53 → Cloudflare cutover

The CronJob writes the current active-WAN public IP to
`wind.etherport.net` every minute, so the apex always points at the
live WAN. After 2026-05-27's Route53 zone deletion, every run failed
with `NoSuchHostedZone` and the CronJob was suspended in source.

This runbook walks through the cutover. Most of the IaC is already
in place; the user only pastes a CF token + uncomments a kustomization
entry.

## What's already in code

- `platform/kubernetes/cloudflare-ddns/image/scripts/update-cf-dns.sh` —
  rewritten to use `curl` + jq against the Cloudflare REST API.
  Drops `aws route53` calls entirely. Same IP-source logic
  (`auto` / DNS / HTTP service) preserved.
- `platform/kubernetes/cloudflare-ddns/base/configmap.yaml` — `hosted_zones`
  replaced with `cf_zone_id`. AWS_* envs gone.
- `platform/kubernetes/cloudflare-ddns/base/cronjob.yaml` — env vars
  switched to CF_ZONE_ID + envFrom now references
  `cloudflare-credentials` Secret.
- `platform/kubernetes/cloudflare-ddns/base/cloudflare-credentials.sops.yaml.template`
  — SOPS-encrypted Secret manifest with `CF_API_TOKEN` placeholder.
- `kustomization.yaml` still lists the OLD `01-route53-secret.sops.yaml`
  + the CronJob is still `suspend: true`. The user takes the
  uncomment/un-suspend steps as the final cutover action.

## User-side cutover (one-time, ~3 min)

### 1. Get a Cloudflare API token

Reuse the existing `cloudflare-tf-token` (already has Zone:DNS:Edit
on etherport.net) OR create a dedicated `cloudflare-ddns` token for
independent rotation.

### 2. Create the encrypted secret

```bash
cd platform/kubernetes/cloudflare-ddns/base
cp cloudflare-credentials.sops.yaml.template cloudflare-credentials.sops.yaml
sops cloudflare-credentials.sops.yaml
# Replace REPLACE_WITH_CF_TOKEN with the actual token. Save + quit.
```

### 3. Update kustomization.yaml + un-suspend

```bash
# Add the new secret, drop the old:
sed -i '' 's|^  - 01-route53-secret.sops.yaml$|  - cloudflare-credentials.sops.yaml|' \
  platform/kubernetes/cloudflare-ddns/base/kustomization.yaml

# Un-suspend the CronJob:
sed -i '' 's|^  suspend: true$|  suspend: false|' \
  platform/kubernetes/cloudflare-ddns/base/cronjob.yaml
```

### 4. Commit + push

```bash
git add platform/kubernetes/cloudflare-ddns/
git commit -m "cloudflare-ddns: cut over to Cloudflare + un-suspend"
git push
```

### 5. Wait for Flux + verify

```bash
flux reconcile kustomization flux-system
# Within 1 min after suspend=false, the next CronJob will fire.

kubectl -n cloudflare-ddns get jobs --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n cloudflare-ddns logs -l app=cloudflare-ddns --tail=40
# Expected header: "Cloudflare Dynamic DNS Updater"
# Expected status: "No change needed" (since wind.etherport.net
# already = 47.159.189.5) or "Updated successfully" if WAN IP differs.
```

### 6. Confirm a real write works (optional)

Temporarily edit `wind.etherport.net` in CF dashboard to a known-wrong
value (e.g., `192.0.2.99`). Wait 1 min. The next CronJob run should
detect the diff and PUT the actual WAN1 IP back.

## Post-cutover cleanup (~5 min)

After confirming the new path is healthy:

```bash
# 1. Delete the old AWS-cred SOPS file + template:
git rm platform/kubernetes/cloudflare-ddns/base/01-route53-secret.sops.yaml \
       platform/kubernetes/cloudflare-ddns/base/01-route53-secret.sops.yaml.template \
       platform/kubernetes/cloudflare-ddns/base/secret-template.yaml

# 2. Delete the live AWS-cred Secret (Flux pruning would do this in ~10
#    min anyway; manual is faster):
kubectl -n cloudflare-ddns delete secret cloudflare-ddns-credentials

# 3. Revoke the AWS access key on the IAM user that backed it.
#    (Look up which IAM user owned AKIA... and delete that key.)

# 4. Optional: rebuild the image to drop aws-cli (saves ~50MB). Run
#    `.github/workflows/cloudflare-ddns-image.yml` after a Dockerfile
#    edit. Not blocking — script doesn't use aws-cli anymore.

# 5. Update outstanding-work.md + close task #84.
```

## Rollback

If the new path is broken: re-suspend the CronJob (`suspend: true` in
cronjob.yaml). The static `wind = 47.159.189.5` value in
`infra/terraform/cloudflare/variables.tf` keeps DNS resolving while
you debug. WAN-failover detection is broken under both states.

## Why we kept the directory name "cloudflare-ddns"

Rename across `platform/kubernetes/cloudflare-ddns/`, the K8s namespace,
the image registry path, the CI workflow, the ServiceAccount, RBAC,
and PromQL `cloudflare_ddns_*` metric names is a separate cleanup not
worth doing under time pressure. The script and configs are
authoritative; the path name is just history.
