# Terraform IAM Policies

IAM policies for the `terraform-homelab` user, organized into groups for AWS's 10-policy-per-user limit.

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
| terraform-state | Terraform state backend (S3 bucket and DynamoDB) |

### terraform-integration
| Policy | Description |
|--------|-------------|
| terraform-eventbridge | EventBridge rule management for scheduled tasks |
| terraform-external-monitoring | Route53 health checks, SNS topics, CloudWatch alarms for external monitoring |

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

Each `.json` file contains the IAM policy document matching the AWS policy of the same name (without `.json` extension).
