# SOPS Secret Management Setup

This guide shows how to encrypt Kubernetes secrets with [Mozilla SOPS](https://github.com/getsops/sops) and [age](https://github.com/FiloSottile/age).

## Why SOPS?

**Benefits:**
- ✅ Secrets encrypted in git (safe to commit)
- ✅ Version controlled (track secret changes)
- ✅ Auditable (see who changed what, when)
- ✅ Easy decryption for authorized users
- ✅ Integrates with Flux, ArgoCD, GitOps tools

**Without SOPS:**
- ❌ Secrets managed manually (`kubectl create secret`)
- ❌ Not in git (no version history)
- ❌ Hard to track changes
- ❌ Manual rotation/updates

## Installation

### macOS
```bash
brew install sops age
```

### Linux
```bash
# age
wget https://github.com/FiloSottile/age/releases/latest/download/age-linux-amd64.tar.gz
tar xzf age-linux-amd64.tar.gz
sudo mv age/age* /usr/local/bin/

# SOPS
wget https://github.com/getsops/sops/releases/latest/download/sops-linux-amd64
chmod +x sops-linux-amd64
sudo mv sops-linux-amd64 /usr/local/bin/sops
```

## Initial Setup

### 1. Generate age Key Pair

```bash
# Create directory
mkdir -p ~/.config/sops/age

# Generate key pair
age-keygen -o ~/.config/sops/age/keys.txt

# Output shows:
# Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
# (your public key will be different)
```

**Important:**
- Private key is in `~/.config/sops/age/keys.txt` - **KEEP THIS SAFE!**
- Public key is shown in output - this goes in `.sops.yaml`

### 2. Configure SOPS

Each directory with encrypted secrets needs a `.sops.yaml`:

```yaml
# platform/kubernetes/route53-ddns/.sops.yaml
creation_rules:
  - path_regex: \.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

**Multiple users:**
```yaml
creation_rules:
  - path_regex: \.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p,
      age1vzaqy5qrqmwmx5vlcf6nq7gdwzq6y8w8s8vn8e4z8w7s5v6n8e4z8w7s5v
```

### 3. Set SOPS Age Key Environment Variable

Add to `~/.bashrc` or `~/.zshrc`:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

Or for current session:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

## Creating Encrypted Secrets

### Method 1: Create from Scratch

```bash
# Create a new encrypted secret
cat > route53-ddns/base/secret.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: route53-ddns-credentials
  namespace: route53-ddns
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: ""
  AWS_SECRET_ACCESS_KEY: ""
EOF

# Encrypt and edit in one step
sops route53-ddns/base/secret.enc.yaml

# This opens your editor with the secret file
# Fill in the values, save, and exit
# File is automatically encrypted on save
```

### Method 2: Encrypt Existing Secret

```bash
# Export existing secret from Kubernetes
kubectl get secret route53-ddns-credentials -n route53-ddns -o yaml > secret.yaml

# Remove managed fields
yq eval 'del(.metadata.managedFields, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' secret.yaml > clean-secret.yaml

# Encrypt it
sops -e clean-secret.yaml > route53-ddns/base/secret.enc.yaml

# Clean up
rm secret.yaml clean-secret.yaml
```

### Method 3: One-Liner from kubectl

```bash
kubectl create secret generic route53-ddns-credentials \
  --namespace=route53-ddns \
  --from-literal=AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  --from-literal=AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  --dry-run=client -o yaml | \
  sops -e /dev/stdin > route53-ddns/base/secret.enc.yaml
```

## Using Encrypted Secrets

### View Encrypted File (Raw)

```bash
cat route53-ddns/base/secret.enc.yaml
```

Output shows encrypted content:
```yaml
apiVersion: v1
kind: Secret
metadata:
    name: route53-ddns-credentials
    namespace: route53-ddns
type: Opaque
stringData:
    AWS_ACCESS_KEY_ID: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
    AWS_SECRET_ACCESS_KEY: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
sops:
    kms: []
    age:
        - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
          enc: |
            -----BEGIN AGE ENCRYPTED FILE-----
            ...
            -----END AGE ENCRYPTED FILE-----
```

### Decrypt and View

```bash
# Decrypt to stdout
sops -d route53-ddns/base/secret.enc.yaml

# Decrypt to file
sops -d route53-ddns/base/secret.enc.yaml > secret.yaml
```

### Edit Encrypted Secret

```bash
# Opens decrypted version in editor
# Automatically re-encrypts on save
sops route53-ddns/base/secret.enc.yaml
```

### Deploy to Kubernetes

```bash
# Decrypt and apply
sops -d route53-ddns/base/secret.enc.yaml | kubectl apply -f -

# Or add to kustomization.yaml with SOPS generator (requires KSOPS)
```

## Git Integration

### Add Encrypted Secrets to Git

```bash
# Encrypted files are SAFE to commit
git add route53-ddns/base/secret.enc.yaml
git add route53-ddns/.sops.yaml
git commit -m "Add SOPS-encrypted Route53 credentials"
git push
```

### .gitignore Pattern

Update `.gitignore` to only ignore unencrypted secrets:

```gitignore
# Ignore unencrypted secrets
**/secret.yaml
**/*-secret.yaml

# Allow encrypted secrets
!**/*.enc.yaml
!**/.sops.yaml
```

## Team Collaboration

### Sharing Secrets with Team Members

**Option 1: Share age private key (simple, less secure)**
```bash
# Sender encrypts and shares age private key
gpg -c ~/.config/sops/age/keys.txt
# Send keys.txt.gpg to team member securely

# Receiver decrypts
gpg -d keys.txt.gpg > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

**Option 2: Multiple age recipients (better)**
```bash
# Each team member generates their own age key
age-keygen -o ~/.config/sops/age/keys.txt

# Update .sops.yaml with all public keys
creation_rules:
  - path_regex: \.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p,
      age1vzaqy5qrqmwmx5vlcf6nq7gdwzq6y8w8s8vn8e4z8w7s5v6n8e4z8w7s5v

# Re-encrypt existing secrets for new recipients
sops updatekeys route53-ddns/base/secret.enc.yaml
```

### Adding New Team Member

```bash
# 1. New member generates key and shares public key
age-keygen -o ~/.config/sops/age/keys.txt
# Public key: age1xyz...

# 2. Add to .sops.yaml
# (append to age: list)

# 3. Update all encrypted files
find . -name "*.enc.yaml" -exec sops updatekeys {} \;

# 4. Commit updated .sops.yaml and re-encrypted files
git add .sops.yaml **/*.enc.yaml
git commit -m "Add new team member to SOPS encryption"
```

## Flux/GitOps Integration

If using Flux for GitOps, install SOPS support:

```bash
# Install SOPS controller
flux bootstrap github \
  --owner=sparked-diamond \
  --repository=infra \
  --path=./clusters/production \
  --personal

# Create age secret in flux-system namespace
cat ~/.config/sops/age/keys.txt | \
  kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin

# Configure Kustomization to decrypt SOPS secrets
flux create kustomization route53-ddns \
  --source=GitRepository/flux-system \
  --path="./platform/kubernetes/route53-ddns/base" \
  --prune=true \
  --interval=5m \
  --decryption-provider=sops \
  --decryption-secret=sops-age
```

## Security Best Practices

### DO:
- ✅ Keep age private key in `~/.config/sops/age/keys.txt`
- ✅ Back up age private key to password manager
- ✅ Use separate age keys for different environments (dev/prod)
- ✅ Rotate secrets periodically
- ✅ Commit `.sops.yaml` and `*.enc.yaml` files to git
- ✅ Use `encrypted_regex` to only encrypt sensitive fields

### DON'T:
- ❌ Commit unencrypted secrets (*.yaml without .enc)
- ❌ Share age private key via insecure channels
- ❌ Use same age key across organizations
- ❌ Lose your age private key (no recovery!)
- ❌ Commit age private key to git

## Troubleshooting

### "Failed to get the data key"

**Cause:** SOPS can't find your age private key

**Fix:**
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

### "no key could decrypt the data key"

**Cause:** File encrypted for different age public key

**Fix:**
- Get correct age private key from team
- Or re-encrypt file with your public key

### "MAC mismatch"

**Cause:** Encrypted file corrupted or tampered with

**Fix:** Restore from git history or re-encrypt

## Examples

### Route53 DDNS Secret

```bash
# Create encrypted secret
sops route53-ddns/base/secret.enc.yaml

# Edit content (SOPS opens your editor):
apiVersion: v1
kind: Secret
metadata:
  name: route53-ddns-credentials
  namespace: route53-ddns
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: AKIAIOSFODNN7EXAMPLE
  AWS_SECRET_ACCESS_KEY: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLE

# Save and exit - file is encrypted automatically

# Deploy
sops -d route53-ddns/base/secret.enc.yaml | kubectl apply -f -

# Commit safely
git add route53-ddns/base/secret.enc.yaml
git commit -m "Add Route53 credentials"
```

### S3 Backup Credentials

```bash
# Same process for backup credentials
sops backups/aws-s3/base/secret.enc.yaml

# Edit:
apiVersion: v1
kind: Secret
metadata:
  name: aws-backup-credentials
  namespace: backups
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: AKIAIOSFODNN7EXAMPLE
  AWS_SECRET_ACCESS_KEY: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLE

# Deploy
sops -d backups/aws-s3/base/secret.enc.yaml | kubectl apply -f -
```

## Practical Workflows

### Adding Secrets to an Application (e.g., Home Assistant)

This workflow shows how to add credentials to an app that reads a `secrets.yaml` file.

**1. Create the SOPS config in the app directory:**

```bash
cd platform/kubernetes/home-automation/

cat > .sops.yaml <<'EOF'
creation_rules:
  - path_regex: '.*\.sops\.ya?ml$'
    encrypted_regex: '^(data|stringData)$'
    age: age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g
EOF
```

**2. Create the secret file:**

```bash
cat > secrets.sops.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: home-assistant-secrets
  namespace: home-automation
type: Opaque
stringData:
  secrets.yaml: |
    # Home Assistant secrets.yaml content
    my_password: supersecret123
    api_key: abc123xyz
EOF
```

**3. Encrypt it:**

```bash
sops -e -i secrets.sops.yaml
```

**4. Add to kustomization.yaml:**

```yaml
resources:
  - secrets.sops.yaml
```

**5. Mount in deployment:**

```yaml
volumeMounts:
  - name: secrets
    mountPath: /config/secrets.yaml
    subPath: secrets.yaml
    readOnly: true
volumes:
  - name: secrets
    secret:
      secretName: home-assistant-secrets
```

**6. Reference in app config:**

```yaml
# configuration.yaml
light:
  - platform: decora_wifi
    username: !secret my_username
    password: !secret my_password
```

**7. Commit and push:**

```bash
git add .sops.yaml secrets.sops.yaml kustomization.yaml
git commit -m "Add encrypted secrets for home-assistant"
git push
flux reconcile source git flux-system
```

### How Decryption Works

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Git Repo      │     │   Flux          │     │   Kubernetes    │
│                 │     │                 │     │                 │
│  secrets.sops   │────►│  Decrypts with  │────►│  Secret object  │
│  (encrypted)    │     │  age key        │     │  (plaintext)    │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │   Pod           │
                                                │                 │
                                                │  /config/       │
                                                │  secrets.yaml   │
                                                │  (plaintext)    │
                                                └─────────────────┘
```

**Where secrets are plaintext:**
- Kubernetes Secret object (stored in etcd, base64-encoded but not encrypted)
- Mounted file inside the pod container

**Where secrets are encrypted:**
- Git repository (SOPS encrypted)

This is standard practice. SOPS protects secrets in version control. For etcd encryption at rest, see [Kubernetes Encryption at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/).

### Editing an Existing Secret

```bash
# Opens decrypted in your editor, re-encrypts on save
sops platform/kubernetes/home-automation/secrets.sops.yaml

# After editing, commit and reconcile
git add secrets.sops.yaml
git commit -m "Update home-assistant credentials"
git push
flux reconcile source git flux-system
```

### Viewing Decrypted Content

```bash
# View decrypted secret locally
sops -d platform/kubernetes/home-automation/secrets.sops.yaml

# View what's actually in the cluster
kubectl get secret home-assistant-secrets -n home-automation -o jsonpath='{.data.secrets\.yaml}' | base64 -d
```

## Related Documentation

- [1Password CLI Integration](1PASSWORD-CLI.md)
- [SOPS vs Ansible-Vault Decision](decisions/sops-vs-ansible-vault.md)
- [GitOps with Flux](gitops/flux-overview.md)

## External References

- [SOPS Documentation](https://github.com/getsops/sops)
- [age Encryption](https://github.com/FiloSottile/age)
- [Flux SOPS Guide](https://fluxcd.io/docs/guides/mozilla-sops/)
