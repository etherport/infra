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
# platform/kubernetes/cloudflare-ddns/.sops.yaml
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
cat > cloudflare-ddns/base/cloudflare-credentials.sops.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-credentials
  namespace: cloudflare-ddns
type: Opaque
stringData:
  CF_API_TOKEN: ""
EOF

# Encrypt and edit in one step
sops cloudflare-ddns/base/cloudflare-credentials.sops.yaml

# This opens your editor with the secret file
# Fill in the values, save, and exit
# File is automatically encrypted on save
```

### Method 2: Encrypt Existing Secret

```bash
# Export existing secret from Kubernetes
kubectl get secret cloudflare-credentials -n cloudflare-ddns -o yaml > secret.yaml

# Remove managed fields
yq eval 'del(.metadata.managedFields, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' secret.yaml > clean-secret.yaml

# Encrypt it
sops -e clean-secret.yaml > cloudflare-ddns/base/cloudflare-credentials.sops.yaml

# Clean up
rm secret.yaml clean-secret.yaml
```

### Method 3: One-Liner from kubectl

```bash
kubectl create secret generic cloudflare-credentials \
  --namespace=cloudflare-ddns \
  --from-literal=CF_API_TOKEN=REPLACE_WITH_CF_TOKEN \
  --dry-run=client -o yaml | \
  sops -e /dev/stdin > cloudflare-ddns/base/cloudflare-credentials.sops.yaml
```

## Using Encrypted Secrets

### View Encrypted File (Raw)

```bash
cat cloudflare-ddns/base/cloudflare-credentials.sops.yaml
```

Output shows encrypted content:
```yaml
apiVersion: v1
kind: Secret
metadata:
    name: cloudflare-credentials
    namespace: cloudflare-ddns
type: Opaque
stringData:
    CF_API_TOKEN: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
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
sops -d cloudflare-ddns/base/cloudflare-credentials.sops.yaml

# Decrypt to file
sops -d cloudflare-ddns/base/cloudflare-credentials.sops.yaml > secret.yaml
```

### Edit Encrypted Secret

```bash
# Opens decrypted version in editor
# Automatically re-encrypts on save
sops cloudflare-ddns/base/cloudflare-credentials.sops.yaml
```

### Deploy to Kubernetes

```bash
# Decrypt and apply
sops -d cloudflare-ddns/base/cloudflare-credentials.sops.yaml | kubectl apply -f -

# Or add to kustomization.yaml with SOPS generator (requires KSOPS)
```

## Git Integration

### Add Encrypted Secrets to Git

```bash
# Encrypted files are SAFE to commit
git add cloudflare-ddns/base/cloudflare-credentials.sops.yaml
git add cloudflare-ddns/.sops.yaml
git commit -m "Add SOPS-encrypted Cloudflare credentials"
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

## Recipients (single-owner repo)

This is a single-owner repo with **two fixed age recipients** on every
`*.sops.yaml`: the PRIMARY key
(`age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g`, held on the
devbox + mini + GH `SOPS_AGE_KEY` + Flux `sops-age`) and the offline BACKUP
(`age1phcm…3466`, break-glass only). New per-component `.sops.yaml` files must
list **both** (see the home-automation example below). To rotate/re-key after a
recipient change, re-encrypt in place:

```bash
find . -name '*.sops.yaml' -exec sops updatekeys {} \;
```

## Flux/GitOps Integration

Flux is already bootstrapped against `main` → `./clusters/wind` (the
controllers + GitRepository/Kustomization manifests live under
`clusters/wind/flux-system/`). To wire SOPS decryption into it:

```bash
# Create the age secret in the flux-system namespace (decryption key).
# This is a one-time step; the controllers consume it via decryption.secretRef.
cat ~/.config/sops/age/keys.txt | \
  kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
```

Then enable SOPS decryption **declaratively** in the Kustomization manifest
(GitOps — there is no `flux` CLI on the ops hosts). Add a `decryption` block
to the relevant Kustomization (e.g. `clusters/wind/flux-system/gotk-sync.yaml`
or a per-app Kustomization), commit, and let Flux reconcile:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cloudflare-ddns
  namespace: flux-system
spec:
  interval: 5m
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./platform/kubernetes/cloudflare-ddns/base
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

```bash
# Commit + push, then trigger a reconcile (annotation — no flux CLI on hosts):
git add clusters/wind/flux-system/gotk-sync.yaml
git commit -m "Enable SOPS decryption for cloudflare-ddns"
git push
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
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

### Cloudflare DDNS Secret

The `cloudflare-ddns` CronJob keeps the public DNS records in sync via the
Cloudflare API (it migrated off Route53 on 2026-05-27 — the directory name is
historical). It reads a single `CF_API_TOKEN` from the
`cloudflare-credentials` secret.

```bash
# Create encrypted secret
sops platform/kubernetes/cloudflare-ddns/base/cloudflare-credentials.sops.yaml

# Edit content (SOPS opens your editor):
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-credentials
  namespace: cloudflare-ddns
type: Opaque
stringData:
  # Cloudflare API token scoped to Zone:Read + DNS:Edit on etherport.net
  CF_API_TOKEN: REPLACE_WITH_CF_TOKEN

# Save and exit - file is encrypted automatically

# Deploy (or just commit + let Flux reconcile it)
sops -d platform/kubernetes/cloudflare-ddns/base/cloudflare-credentials.sops.yaml | kubectl apply -f -

# Commit safely
git add platform/kubernetes/cloudflare-ddns/base/cloudflare-credentials.sops.yaml
git commit -m "Add Cloudflare DDNS credentials"
```

### S3 Backup Credentials

> **SUPERSEDED by IRSA (M75).** In-cluster AWS workloads (velero, the s3-sync
> backup family, CNPG Barman, …) no longer use a static `aws-backup-credentials`
> secret. They get short-lived AWS creds via `AssumeRoleWithWebIdentity` using a
> projected ServiceAccount token — **there is no static AWS key in etcd to
> encrypt with SOPS.** See `docs/runbooks/irsa-workload-identity.md`. The recipe
> below is retained only as a generic example of encrypting a key-style secret
> for any non-IRSA case.

```bash
# Generic example — encrypting a static key secret with SOPS
sops platform/kubernetes/<app>/secret.sops.yaml

# Edit:
apiVersion: v1
kind: Secret
metadata:
  name: <app>-credentials
  namespace: <app>
type: Opaque
stringData:
  SOME_API_KEY: REPLACE_ME

# Deploy
sops -d platform/kubernetes/<app>/secret.sops.yaml | kubectl apply -f -
```

## Practical Workflows

### Adding Secrets to an Application (e.g., Home Assistant)

This workflow shows how to add credentials to an app that reads a `secrets.yaml` file.

**1. Create the SOPS config in the app directory:**

```bash
cd platform/kubernetes/home-automation/

# Both recipients (PRIMARY + offline BACKUP) so new files match the repo-wide set:
cat > .sops.yaml <<'EOF'
creation_rules:
  - path_regex: '.*\.sops\.ya?ml$'
    encrypted_regex: '^(data|stringData)$'
    age: age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g,age1phcmcgfeqr66t7kxdafckp860y67j6n6y2qrn76hk4fm2vd59pxsqr3466
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
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
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
kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
```

### Viewing Decrypted Content

```bash
# View decrypted secret locally
sops -d platform/kubernetes/home-automation/secrets.sops.yaml

# View what's actually in the cluster
kubectl get secret home-assistant-secrets -n home-automation -o jsonpath='{.data.secrets\.yaml}' | base64 -d
```

## 1Password CLI (`op`) quick-reference

> Merged here from the former `1PASSWORD-CLI.md` (M68). 1Password holds the
> original plaintext secrets; the **canonical pipeline** is `op` → SOPS via
> `scripts/sync-secrets.py` + its manifest — see that script, not ad-hoc `op`
> calls, for how a secret actually lands in the repo.

**⚠️ `op` is operator-only.** It authorizes against the **user's interactive /
VNC desktop session**, not an agent's headless bash and not the Mac mini's
unattended shell. Don't try to drive `op` from automation — for headless work,
read the agent-readable SOPS bundle
(`infra/ansible/playbooks/secrets/homelab-ops.sops.yaml`) instead. If the bundle
lacks a value, the operator dumps it from `op` in their VNC terminal.

```bash
# Always reference items by ID in scripts (names change, IDs don't);
# always use --reveal for concealed (password) fields.
op item get <ITEM_ID> --fields label=username
op item get <ITEM_ID> --fields label=password --reveal

# Find an item's ID
op item list | grep -i "<name>"
op item get "<Item Name>" --format json | jq -r '.id'
```

Known items: `AWS Key (Terraform)` = `ojbjsshj45oup6mcu3vlxxb7re`
(`username`=access key, `password`=secret; backs the Terraform S3 backend).
To push an `op` value into the repo, prefer `scripts/sync-secrets.py`; for a
one-off, fetch with `op` then `sops -e -i` the target `*.sops.yaml`.

**Troubleshooting:** `"no saved authentication found"` → `eval $(op signin)` (or
enable desktop biometric unlock); invalid-character errors on item names → use
the item **ID** instead.

## Related Documentation

- [GitOps with Flux](../gitops/flux-overview.md)
- [Secrets rotation runbook](../../runbooks/secrets-rotation.md)

## External References

- [SOPS Documentation](https://github.com/getsops/sops)
- [age Encryption](https://github.com/FiloSottile/age)
- [Flux SOPS Guide](https://fluxcd.io/docs/guides/mozilla-sops/)
