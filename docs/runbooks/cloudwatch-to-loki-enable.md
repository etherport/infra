# CloudWatch Logs → Loki Forwarder (M45 Phase C) — Enable Runbook

Closes the gap where AWS-side logs only existed in CloudWatch and
weren't visible in Loki/Grafana alongside on-prem K8s + syslog
streams. After this is enabled, every Lambda + EC2-CloudWatch-agent
log group flows into Loki within 5 minutes; queries + dashboards
can span both worlds.

## What it deploys

- Namespace: `cloudwatch-to-loki`
- ServiceAccount + Role with permission to read/write a single
  ConfigMap (`cloudwatch-to-loki-state`) holding per-log-group
  watermarks. No cluster-wide perms.
- SOPS secret `aws-cloudwatch-creds` — reuses the
  `ai-advisor-readonly` IAM user from M45 Phase B (scoped CloudWatch
  Logs read). Placeholder shipped; you populate.
- ConfigMap `cloudwatch-to-loki-script` — pure-Python forwarder
  (~180 lines). No third-party logging stack (Vector / FluentBit /
  Promtail) — just boto3 + urllib + the k8s client.
- CronJob `cloudwatch-to-loki` — runs every 5 min. Discovers log
  groups under configured prefixes, fetches events since the last
  successful run's watermark, pushes to Loki via the standard
  push API, updates the watermark.

## Prerequisites

M45 Phase B must already be running so the IAM user exists. Verify:

```bash
gh workflow view terraform-ai-advisor-iam.yml | head -5
# Should show the most recent apply was successful.
```

Or just check the secret exists in auto-remediation:

```bash
kubectl get secret ai-advisor-aws-cloudwatch -n auto-remediation
```

## Steps

### 1. Populate the SOPS secret

K8s secrets are namespaced; the M45 Phase B secret lives in
`auto-remediation` and can't be cross-mounted. Mirror the same
values into the new `cloudwatch-to-loki` secret:

```bash
sops platform/kubernetes/cloudwatch-to-loki/01-aws-creds.sops.yaml
```

Replace the two `REPLACE` placeholders with the same access key
ID + secret access key you put in the auto-remediation secret
earlier (Phase B step 2).

If you've forgotten the values, re-fetch from Terraform:

```bash
cd infra/terraform/aws/ai-advisor-iam
terraform init -reconfigure
terraform output -raw access_key_id
terraform output -raw access_key_secret
```

Save the sops file. It re-encrypts on save.

### 2. Commit + push

```bash
git add platform/kubernetes/cloudwatch-to-loki/01-aws-creds.sops.yaml
git commit -m "M45 P C: populate cloudwatch-to-loki AWS creds"
git push
```

Flux reconciles within ~1min. CronJob ships; first run on the next
5-min boundary.

### 3. Watch the first run

```bash
# Watch the first job pod come up:
kubectl get pods -n cloudwatch-to-loki -w

# After it completes, check the run output:
kubectl logs -n cloudwatch-to-loki -l job-name=cloudwatch-to-loki-XXXXXX

# Should look like:
#   discovered N log groups under prefixes [/aws/lambda, /aws/ec2, CloudWatchAgent]
#     /aws/lambda/ddns-updater: 5 events
#     /aws/lambda/dns-restrict-ip: 12 events
#     /aws/lambda/email-forward: 0 events  (no print line — only non-empty groups log)
#   done: 17 events pushed; state saved
```

### 4. Verify in Grafana

```logql
{job="cloudwatch"}                                       # everything from CW
{job="cloudwatch", cloud="aws"}                          # same
{job="cloudwatch", service_name="ddns-updater"}          # one specific Lambda
{job="cloudwatch", log_group=~"/aws/lambda/.*"}          # all Lambdas
{job="cloudwatch"} |~ "(?i)error|exception"              # AWS errors anywhere
{job="cloudwatch", log_group=~"CloudWatchAgent.*"}       # EC2 cloudwatch agent
```

In Grafana → Explore → Loki, the **Service Browser** should show
each Lambda function as its own service_name (the last path
segment of the log group).

## Tuning

| Env | Default | Effect |
|---|---|---|
| `LOG_GROUP_PREFIXES` | `/aws/lambda,/aws/ec2,CloudWatchAgent` | What to scan |
| `LOKI_PUSH_URL` | in-cluster Loki | Override only for testing |
| `LOOKBACK_MIN_FRESH` | `30` | How far back to seed a NEW log group on first scan |
| `MAX_EVENTS_PER_GROUP` | `5000` | Hard ceiling per group per run (prevents runaway ingest from a Lambda log explosion) |

## Cost

CloudWatch Logs API:
- `DescribeLogGroups`: free
- `FilterLogEvents`: $0.005 per GB scanned

For typical homelab Lambda volume (~few MB/day across all functions),
each 5-min run scans ~kB → effectively free. EC2 CloudWatch agent
streams more (~MB/day per instance with 2 instances) → still well
under $1/month.

Loki ingest: counts against the daily ingest rate cap in
`clusters/wind/helm-releases/loki.yaml` (`ingestion_rate_mb: 10`).
AWS-side volume is tiny compared to UDM syslog + K8s pod logs;
no risk of saturating.

## What's NOT covered (and why)

- **AWS Route53 query logs** — not currently enabled (would be
  another `aws_route53_query_log` resource in TF). When enabled,
  add `/aws/route53/` to `LOG_GROUP_PREFIXES`.
- **ALB access logs** — Velero/ELB writes to S3, not CloudWatch.
  To get into Loki: separate S3-event-driven Lambda → Loki push.
  Out of scope for Phase C; tracked as L16 if needed.
- **CloudTrail** — control-plane audit logs are noisy + already
  searchable in the AWS console. Add only if you actually need
  unified audit. Big ingest volume.

## Rollback

```bash
# Suspend the CronJob (keeps state, easy resume):
kubectl patch cronjob cloudwatch-to-loki -n cloudwatch-to-loki \
  -p '{"spec":{"suspend":true}}'

# Or full revert:
git revert <commit>
git push
# Or delete the directory:
git rm -r platform/kubernetes/cloudwatch-to-loki
# Then remove the line in clusters/wind/kustomization.yaml.
```

Watermark ConfigMap survives namespace deletion only if you
explicitly preserve it; otherwise on re-enable you'd start fresh
(re-ingesting the last 30min via `LOOKBACK_MIN_FRESH`).

## Audit + observability

Each CronJob run leaves a Job in history (`successfulJobsHistoryLimit:
3, failedJobsHistoryLimit: 5`). Failures are visible via:

```bash
kubectl get jobs -n cloudwatch-to-loki --sort-by=.status.startTime | tail -5
```

For longer-term tracking, run pod logs are scraped by Alloy into
Loki (so the forwarder's own logs are searchable as
`{namespace="cloudwatch-to-loki"}`).
