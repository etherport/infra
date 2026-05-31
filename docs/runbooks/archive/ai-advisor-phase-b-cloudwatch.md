# AI Advisor — M45 Phase B Enable (CloudWatch Logs context)

Phase B extends the advisor's context fetch to include AWS-side
CloudWatch Logs. With this on, alerts about Lambda functions or
EC2 instances in the AWS VPC (10.10.100.0/24) get diagnosed with
the actual recent log entries from those resources, not just
on-prem Loki + K8s context.

**Out of the box without Phase B**: alerts about `dns-aws` /
`vpn-aws` / any Lambda fall through to advisor with empty
`ctx.cloudwatch` (the field is absent). Claude has no AWS-side
log visibility, diagnoses on metadata only.

**With Phase B**: Claude gets up to 80 recent CW log entries from
the relevant log group(s) for the time window around the alert.

## Prerequisites

Phase 1 + Phase 2 must already be running. Verify:

```bash
kubectl logs -n auto-remediation deploy/remediation-controller | head -3
# Expected: "(ai_advisor=on, phase2=ready, daily_cap=$0.5, ...)"
```

## Steps

### 1. Provision the IAM user via Terraform

```bash
gh workflow run terraform-ai-advisor-iam.yml -f action=plan
# Review the plan in the run summary, then:
gh workflow run terraform-ai-advisor-iam.yml -f action=apply
```

Creates `ai-advisor-readonly` IAM user under `/services/` with a
scoped policy: `logs:GetLogEvents`, `logs:FilterLogEvents`,
`logs:StartQuery`, `logs:GetQueryResults`, `logs:DescribeLogGroups`,
`logs:DescribeLogStreams` — **only** on log groups matching
`/aws/lambda/*`, `/aws/ec2/*`, `CloudWatchAgent*`.

### 2. Capture the access key + populate the SOPS secret

After apply succeeds, locally:

```bash
cd infra/terraform/aws/ai-advisor-iam
terraform init -reconfigure   # if you haven't run locally before
terraform output -raw access_key_id
terraform output -raw access_key_secret
```

Then encode into the SOPS secret:

```bash
sops platform/kubernetes/auto-remediation/aws-cloudwatch-creds.sops.yaml
```

Replace the two `REPLACE` placeholders with the values you just
printed. Save + close — sops re-encrypts on save.

### 3. Commit + push

```bash
git add platform/kubernetes/auto-remediation/aws-cloudwatch-creds.sops.yaml
git commit -m "M45 P B: populate ai-advisor CloudWatch read creds"
git push
```

Flux reconciles within ~1 min. The controller pod will roll and
pick up the new env vars from the secret on next start.

### 4. Verify

```bash
# Controller log on start should NOT log a boto3 warning.
kubectl logs -n auto-remediation deploy/remediation-controller | grep -i "boto3\|cloudwatch" | head -3
```

If you see `boto3 unavailable for CloudWatch Logs:` the pip install
failed — check pod logs for the install step.

Force a synthetic AWS-tagged alert through the webhook to test:

```bash
kubectl run test-aws -n auto-remediation --rm -i --restart=Never \
  --image=curlimages/curl:latest --quiet --command -- \
  curl -sS -X POST http://remediation-webhook:8080 \
  -H 'Content-Type: application/json' \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "LambdaErrorRateHigh",
        "function": "ddns-updater",
        "severity": "warning"
      },
      "annotations": {
        "summary": "Synthetic test of Phase B CloudWatch fetch.",
        "description": "Verify ctx.cloudwatch populates with /aws/lambda/ddns-updater logs."
      },
      "startsAt": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    }]
  }'
```

Then check the audit log:

```bash
kubectl logs -n auto-remediation deploy/remediation-controller \
  | grep -E "ai_advisor|cloudwatch" | tail -5
```

The advisor's email should mention specifics from the Lambda logs
in its diagnosis (low confidence is fine — the test alert is
synthetic).

## AWS detection heuristics

The advisor triggers CW fetch on any of:

1. `alert.labels.job == "external-nodes"` AND `alert.labels.location == "aws"`
2. `alert.labels.instance` starts with `10.10.100.` (AWS VPC CIDR)
3. `alertname` contains `lambda` (case-insensitive) OR
   summary/description mentions `lambda`

If your AWS-side alerts don't match any of these, the advisor
silently skips CW. Add new heuristics to `_alert_is_aws()` in
`platform/kubernetes/auto-remediation/controller-configmap.yaml`.

## Log group resolution

For Lambda: `/aws/lambda/<function-name>` — read from
`labels.function` / `labels.function_name`.

For EC2: prefix discovery under `/aws/ec2/*`, with fallback to
`CloudWatchAgent*`. Up to 3 groups queried per alert (to bound
token cost).

## Cost impact

CloudWatch FilterLogEvents costs $0.005 per GB scanned. With
`limit=80` events per group, 3 groups, 10min windows: maybe a few
MB per AWS-related alert. **Well under the daily $0.50 advisor
cap** (which only counts Anthropic spend; AWS spend is separate
but small).

CloudWatch API calls themselves are free for FilterLogEvents +
DescribeLogGroups under normal volume.

## Rollback

Delete the access key in AWS console (or `terraform destroy` the
module). Controller's boto3 calls will return 403 → silently fall
through to empty `ctx.cloudwatch`. The advisor still runs, just
without AWS context.

Or set `AWS_ACCESS_KEY_ID=""` in the deployment env — same effect.
