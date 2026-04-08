# Terraform IAM Policies

IAM policies for the `terraform-homelab` user, organized into groups for AWS's 10-policy-per-user limit.

## Administrative Users

### claude-admin

Administrative user for Claude Code to manage IAM policies. Access can be disabled when not in use.

**Policy:** `claude-admin-policy.json`

**Permissions:**
- Create/update/delete customer managed policies (scoped to `terraform-*` names)
- Manage group policy attachments (scoped to `terraform-*` groups)
- Read-only access to list users, groups, roles, and policies
- **Resource discovery** - Read-only access to inventory AWS resources:
  - EC2 (instances, VPCs, security groups, subnets, etc.)
  - Route53 (zones, records, health checks)
  - Lambda (functions, configurations)
  - S3 (bucket listing and metadata, not object contents)
  - SNS (topics, subscriptions)
  - CloudWatch (alarms, log groups, metrics)
  - API Gateway (APIs, stages, resources)
  - Secrets Manager (list/describe only, not secret values)
  - ELB/ALB (load balancers, target groups, listeners)
  - EventBridge (rules, targets)
  - SES (identities, send statistics)
  - DynamoDB (tables)
  - ACM (certificates)
  - WAFv2 (web ACLs)
  - CloudFront (distributions)
  - KMS (keys, aliases)
  - DataSync (tasks, locations, agents)
  - Cost Explorer and Budgets (cost/usage data)
  - Resource tagging

**Setup:**
1. IAM → Users → Create user → Name: `claude-admin` (no console access)
2. IAM → Policies → Create policy → JSON → paste `claude-admin-policy.json`
   - Name: `claude-admin-policy`
   - Description: "Administrative access for Claude Code to manage terraform IAM policies"
3. Attach `claude-admin-policy` to the `claude-admin` user
4. Create access key: User → Security credentials → Create access key → CLI
5. Configure locally:
   ```bash
   aws configure --profile claude-admin
   # Access Key ID: <from step 4>
   # Secret Access Key: <from step 4>
   # Region: us-west-2
   # Output format: json
   ```

**Security:** Deactivate access key when not in use:
- IAM → Users → claude-admin → Security credentials → Access keys → Deactivate

### alertmanager-ses-smtp

SMTP user for Alertmanager to send email notifications via AWS SES.

**Policy:** AmazonSesSendingAccess (AWS Managed)

**Permissions:**
- `ses:SendRawEmail` - Send emails via SES SMTP

**Setup:**
1. IAM → Users → Create user → Name: `alertmanager-ses-smtp` (no console access)
2. Attach AWS managed policy: `AmazonSesSendingAccess`
3. Create SMTP credentials: User → Security credentials → Create SMTP credentials
   - Note: SMTP credentials are different from regular access keys
   - AWS generates the SMTP password from the secret access key
4. Store credentials in Kubernetes:
   ```bash
   # Edit the SOPS-encrypted secret
   sops platform/kubernetes/monitoring/alertmanager-secret.sops.yaml

   # Add the SMTP username and password from step 3
   ```

**Usage:**
- SMTP Server: `email-smtp.us-west-2.amazonaws.com:587`
- From Address: Must be a verified SES identity (e.g., `alerts@etherport.net`)
- Used by: AlertmanagerConfig CR in `platform/kubernetes/monitoring/03-alertmanager-config.yaml`

**Related Files:**
- `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml` - SMTP credentials (SOPS encrypted)
- `platform/kubernetes/monitoring/03-alertmanager-config.yaml` - AlertmanagerConfig CR

## IAM Groups

| Group | Purpose |
|-------|---------|
| terraform-core | Core infrastructure: secrets, IAM roles, CloudWatch logs |
| terraform-compute | Compute resources: Lambda functions, EC2, security groups |
| terraform-storage | Storage and DNS: S3 buckets, Route53, Terraform state |
| terraform-integration | Integration services: EventBridge, SES, API Gateway |

## Policy Assignments

### terraform-core
| Policy | Description |
|--------|-------------|
| terraform-ddns-secrets-iam | Secrets Manager and IAM role management for DDNS Lambda |
| terraform-ddns-logs | CloudWatch log group management for DDNS Lambda |
| terraform-iam-users | IAM user lifecycle management (create users, access keys, policies) |

### terraform-compute
| Policy | Description |
|--------|-------------|
| terraform-ddns-core | Lambda and API Gateway management for DDNS |
| terraform-dns-restrict-ip | Lambda and CloudWatch Events for DNS security group updates |
| terraform-ec2-security-groups | EC2 security group management |
| terraform-email-forward | Lambda and S3 for email forwarding |
| terraform-homeassistant-alexa | Lambda and Secrets Manager for Home Assistant Alexa integration |
| terraform-lambda-manage | General Lambda function management |
| terraform-snapshot-archive | Lambda, EC2 snapshots, and SES for snapshot archiving |

### terraform-storage
| Policy | Description |
|--------|-------------|
| terraform-ddns-state | Terraform state access for DDNS module |
| terraform-state | Terraform state backend (S3 bucket with native locking) |
| terraform-storage | S3 bucket and SES identity management |

### terraform-network
| Policy | Description |
|--------|-------------|
| terraform-networking | VPC, subnets, route tables, security groups, NACLs |
| terraform-compute | EC2 instances, EIPs, snapshots, CloudWatch alarms, SNS topics |
| terraform-loadbalancing | ALB, listeners, target groups, certificates |
| terraform-dns | Route53 hosted zones and DNS records |

### terraform-integration
| Policy | Type | Description |
|--------|------|-------------|
| terraform-eventbridge | Managed | EventBridge rule management for scheduled tasks |
| terraform-external-monitoring | Managed | Route53 health checks, SNS topics, CloudWatch alarms for external monitoring |

Note: All policies are now customer managed (no inline policies).

## Adding New Policies

To add a new policy to an IAM group:
```bash
# Via AWS Console
# 1. Go to IAM → Groups → terraform-integration
# 2. Permissions → Add permissions → Create inline policy
# 3. JSON tab → paste policy content
# 4. Name: terraform-<policy-name>

# Or via CLI (requires admin access)
aws iam put-group-policy \
  --group-name terraform-integration \
  --policy-name terraform-external-monitoring \
  --policy-document file://terraform-external-monitoring.json
```

## Files

| File | Description |
|------|-------------|
| `claude-admin-policy.json` | Administrative policy for Claude Code IAM management |
| `terraform-*.json` | Policies for terraform-homelab user (matches AWS policy names) |
