# 1Password CLI Integration

Quick reference for managing secrets with 1Password CLI in this infrastructure.

## Available Credentials

| 1Password Item | Item ID | Purpose |
|----------------|---------|---------|
| AWS Key (Route 53 Updater) | `ooefsxjnvx4khtbh63tn5fr3pu` | Route53 DDNS updates |
| AWS Key (Kubernetes S3 NAS Backups) | *(get ID)* | S3 backup operations |
| AWS Key (Velero Backups) | *(get ID)* | Velero Kubernetes backups |
| AWS Key (Terraform) | *(get ID)* | Terraform infrastructure |

## Common Commands

### Retrieve Credentials

```bash
# Using item name (requires quotes for names with spaces/parentheses)
op item get "AWS Key (Route 53 Updater)" --fields label=username
op item get "AWS Key (Route 53 Updater)" --fields label=password --reveal

# Using item ID (more reliable in scripts)
op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=username
op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=password --reveal
```

**Important:** Always use `--reveal` flag for password fields (concealed type)

### Get Item IDs

```bash
# List all items and search
op item list | grep -i "route"

# Get specific item details
op item get "AWS Key (Route 53 Updater)" --format json | jq '.id'
```

## Integration Patterns

### Pattern 1: Update SOPS Encrypted Secret

Update Route53 DDNS credentials from 1Password:

```bash
# Navigate to secret directory
cd platform/kubernetes/route53-ddns/base

# Get credentials from 1Password
AWS_ACCESS_KEY_ID=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=username)
AWS_SECRET_ACCESS_KEY=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=password --reveal)

# Create temporary unencrypted file
cat > temp-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: route53-ddns-credentials
  namespace: route53-ddns
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
EOF

# Encrypt with SOPS
export SOPS_AGE_KEY_FILE=/Users/grahamsmith/.config/sops/age/keys.txt
sops -e temp-secret.yaml > 01-route53-secret.sops.yaml

# Clean up
rm temp-secret.yaml

# Verify encryption
sops -d 01-route53-secret.sops.yaml | grep AWS_ACCESS_KEY_ID

# Deploy to Kubernetes
sops -d 01-route53-secret.sops.yaml | kubectl apply -f -
```

### Pattern 2: Direct Kubernetes Secret Update

Update a secret in Kubernetes directly from 1Password (without SOPS):

```bash
kubectl create secret generic route53-ddns-credentials \
  --namespace=route53-ddns \
  --from-literal=AWS_ACCESS_KEY_ID=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=username) \
  --from-literal=AWS_SECRET_ACCESS_KEY=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=password --reveal) \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Pattern 3: Environment Variables for Session

Set up credentials for a session:

```bash
export AWS_ACCESS_KEY_ID=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=username)
export AWS_SECRET_ACCESS_KEY=$(op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=password --reveal)
export AWS_REGION=us-west-2

# Now use AWS CLI
aws route53 list-hosted-zones
```

### Pattern 4: Scripted Secret Rotation

Create a script to rotate credentials across all systems:

```bash
#!/bin/bash
# rotate-route53-creds.sh

set -euo pipefail

ITEM_ID="ooefsxjnvx4khtbh63tn5fr3pu"

echo "Fetching new credentials from 1Password..."
AWS_ACCESS_KEY_ID=$(op item get $ITEM_ID --fields label=username)
AWS_SECRET_ACCESS_KEY=$(op item get $ITEM_ID --fields label=password --reveal)

echo "Updating SOPS encrypted secret..."
cd platform/kubernetes/route53-ddns/base
# ... update and encrypt secret ...

echo "Deploying to Kubernetes..."
sops -d 01-route53-secret.sops.yaml | kubectl apply -f -

echo "Restarting Route53 DDNS pods..."
kubectl delete pods -n route53-ddns -l app=route53-ddns

echo "✅ Credentials rotated successfully"
```

## Working with Claude Code

When working with me (Claude Code), reference 1Password items instead of sharing credentials:

**Instead of:**
> "Here are my AWS credentials: AKIA..."

**Do this:**
> "Get the Route53 credentials from 1Password item ID ooefsxjnvx4khtbh63tn5fr3pu and update the secret"

Then I can run:
```bash
op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=username
op item get ooefsxjnvx4khtbh63tn5fr3pu --fields label=password --reveal
```

Benefits:
- ✅ Credentials never exposed in chat history
- ✅ 1Password audit log tracks all access
- ✅ Biometric unlock provides secure access
- ✅ Easy credential rotation

## Security Best Practices

1. **Always use item IDs in scripts** - Names can change, IDs don't
2. **Use `--reveal` for password fields** - Required for concealed fields
3. **Never commit 1Password output** - Use in-memory variables only
4. **Rotate credentials regularly** - Update in 1Password, then redeploy
5. **Audit access logs** - Check 1Password for unauthorized access

## Troubleshooting

### "no saved authentication found"

```bash
# Sign in to 1Password
eval $(op signin)

# Or configure biometric unlock in 1Password desktop app
```

### "could not read secret"

- Check item name/ID is correct
- Ensure you're using `--reveal` for password fields
- Verify the field label matches (username/password)

### Invalid character errors with item names

Use item IDs instead of names when items contain special characters like parentheses.

## Related Documentation

- [SOPS Secret Management](SOPS-SETUP.md)
- [SOPS vs Ansible-Vault Decision](decisions/sops-vs-ansible-vault.md)

## External References

- [1Password CLI Documentation](https://developer.1password.com/docs/cli/)
