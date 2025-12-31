# SOPS vs Ansible-Vault: Secret Encryption Comparison

**Date**: 2025-12-31
**Context**: Choosing encryption method for Ceph authentication key in Ansible inventory
**Status**: Decision Pending

---

## Current State

**File Requiring Encryption**: `infra/ansible/inventory/wind/group_vars/all/ceph.yml`

```yaml
# Currently plaintext:
ceph_cluster_id: "4de37616-ef82-4295-8ff0-7309d4b34812"
ceph_monitors: ["10.10.201.41:6789"]
ceph_k8s_user: "k8s"
ceph_k8s_key: "AQBwejhp7lzSBBAAxa8TJhMRakcjYeOgMigqtg=="  # ← SENSITIVE
```

**Existing Encryption in Repo**:
- AWS backup credentials: SOPS (`.sops.yaml` configured, AWS KMS)
- Route53 credentials: Not encrypted yet (local file only, in `.gitignore`)

---

## Option 1: Ansible-Vault

### How It Works
Ansible-Vault encrypts entire files or specific variables using symmetric encryption (AES256). Decryption happens automatically during Ansible playbook runs when the vault password is provided.

### Implementation

**Encrypt the file**:
```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/ansible/inventory/wind/group_vars/all/
ansible-vault encrypt ceph.yml
```

**Or encrypt just the key value** (inline string):
```bash
ansible-vault encrypt_string 'AQBwejhp7lzSBBAAxa8TJhMRakcjYeOgMigqtg==' --name 'ceph_k8s_key'
```

Result in file:
```yaml
ceph_k8s_key: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  66386439653...
```

**Usage in playbooks**:
```bash
# Provide vault password at runtime
ansible-playbook -i inventory/wind/inventory.ini site.yml --ask-vault-pass

# Or use password file
ansible-playbook -i inventory/wind/inventory.ini site.yml --vault-password-file ~/.vault_pass
```

### Pros ✅

1. **Native Ansible integration** - No external tools required
2. **Simple workflow** - Decryption happens automatically during playbook execution
3. **Fine-grained encryption** - Can encrypt specific variables or entire files
4. **Widely adopted** - Standard practice in Ansible community
5. **No external dependencies** - Works offline, no KMS/cloud required
6. **Ansible knows how to handle** - `ansible-vault view`, `edit`, `rekey` commands
7. **Existing knowledge** - Team likely familiar with ansible-vault

### Cons ❌

1. **Vault password management** - Need to securely store/share vault password
2. **No git diff visibility** - Encrypted content is opaque in version control
3. **Not portable outside Ansible** - Can't easily decrypt for manual inspection
4. **Single password** - All vaulted content shares same password (unless using vault IDs)
5. **Manual password entry** - Interactive prompts can be annoying (unless using password file)
6. **No key rotation built-in** - Must manually rekey all vaulted content

### Security Model

- **Encryption**: AES256-CBC
- **Key derivation**: PBKDF2 with 10,000 iterations
- **Password storage**: User-managed (file, password manager, or interactive)
- **Access control**: Anyone with vault password can decrypt

---

## Option 2: SOPS (Secrets OPerationS)

### How It Works
SOPS encrypts values in YAML/JSON files while keeping keys visible. Uses external key management (AWS KMS, GPG, Age, etc.). Each file can use different encryption keys.

### Implementation

**Your existing `.sops.yaml` config**:
```yaml
# Located at: platform/kubernetes/backups/aws-s3/.sops.yaml
creation_rules:
  - kms: arn:aws:kms:us-west-2:830881980142:key/4a1d5e90-6bf5-41e0-9ece-e50e88fddc0c
```

**Encrypt the Ceph file**:
```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/ansible/inventory/wind/group_vars/all/

# Create .sops.yaml in ansible directory (or use global config)
cat > ../../.sops.yaml <<EOF
creation_rules:
  - kms: arn:aws:kms:us-west-2:830881980142:key/4a1d5e90-6bf5-41e0-9ece-e50e88fddc0c
EOF

# Encrypt the file
sops --encrypt --in-place ceph.yml
```

**Result** (`ceph.yml` after SOPS encryption):
```yaml
ceph_cluster_id: "4de37616-ef82-4295-8ff0-7309d4b34812"  # ← Visible
ceph_monitors: ["10.10.201.41:6789"]                      # ← Visible
ceph_k8s_user: "k8s"                                      # ← Visible
ceph_k8s_key: ENC[AES256_GCM,data:8f7aQ==,tag:Xy...]      # ← Encrypted
sops:
  kms:
    - arn: arn:aws:kms:us-west-2:830881980142:key/...
      created_at: '2025-12-31T...'
```

**Usage with Ansible**:
Requires a plugin or pre-decryption step. Two common approaches:

**Approach A: Decrypt before running Ansible** (simpler):
```bash
sops --decrypt ceph.yml > ceph.decrypted.yml
ansible-playbook -i inventory/wind/inventory.ini site.yml
rm ceph.decrypted.yml  # Clean up
```

**Approach B: Use sops-ansible plugin**:
```bash
pip install ansible-community-sops
ansible-playbook -i inventory/wind/inventory.ini site.yml
# Plugin auto-decrypts during execution
```

### Pros ✅

1. **Git-friendly diffs** - Keys stay visible, only values encrypted
2. **Centralized key management** - AWS KMS integration (audit logs, rotation)
3. **Multiple keys** - Different files can use different KMS keys
4. **Portable** - Can decrypt outside Ansible with `sops --decrypt`
5. **Already in use** - Consistent with existing AWS backup secret encryption
6. **Better access control** - AWS IAM controls who can decrypt (KMS policies)
7. **Key rotation** - AWS KMS handles rotation automatically
8. **Audit trail** - KMS logs all decrypt operations

### Cons ❌

1. **External dependency** - Requires AWS KMS access (network dependency)
2. **Additional tooling** - Must install `sops` CLI tool
3. **Not native to Ansible** - Requires plugin or manual decryption step
4. **AWS coupling** - Tied to AWS infrastructure (could use GPG/Age instead)
5. **Complexity** - More moving parts than ansible-vault
6. **Offline limitation** - Can't decrypt without AWS KMS access

### Security Model

- **Encryption**: AES256-GCM (per-value)
- **Key management**: AWS KMS (or GPG, Age, GCP KMS, Azure Key Vault)
- **Access control**: AWS IAM policies on KMS key
- **Audit**: CloudTrail logs for all KMS decrypt operations

---

## Comparison Matrix

| Feature | Ansible-Vault | SOPS |
|---------|---------------|------|
| **Ansible integration** | Native ✅ | Plugin required ⚠️ |
| **Git diff visibility** | Opaque ❌ | Keys visible ✅ |
| **Offline usage** | Yes ✅ | Requires KMS access ❌ |
| **Key management** | Manual password | AWS KMS ✅ |
| **Access control** | Shared password | IAM policies ✅ |
| **Audit trail** | None ❌ | CloudTrail ✅ |
| **Learning curve** | Low (Ansible standard) | Medium ⚠️ |
| **Consistency with repo** | New pattern | Matches AWS backup ✅ |
| **Portability** | Ansible-specific | Tool-agnostic ✅ |
| **Team collaboration** | Password sharing required | IAM-based ✅ |

---

## Recommendation

### For Homelab Infrastructure: **SOPS** (recommended)

**Rationale**:
1. **Consistency**: You're already using SOPS for AWS backup credentials
2. **Better for git workflows**: Can see what changed (keys visible, values encrypted)
3. **IAM-based access**: No need to share vault passwords with team members
4. **Audit trail**: KMS logs show who decrypted what and when
5. **Future-proof**: If you add team members, IAM scales better than shared passwords

**Tradeoff acceptance**:
- Accept the AWS KMS dependency (you're already using AWS for backups/DNS)
- Accept the need for `sops` CLI tool and Ansible plugin
- Accept slightly more complex playbook execution initially

### Alternative: **Ansible-Vault** (simpler, Ansible-native)

**When to choose this**:
- You want Ansible-native tooling only
- You prefer offline-first operation
- Team is small and password sharing is acceptable
- You don't need audit trails for compliance

---

## Implementation Plan (if choosing SOPS)

### Step 1: Verify AWS KMS access
```bash
aws kms describe-key --key-id 4a1d5e90-6bf5-41e0-9ece-e50e88fddc0c
```

### Step 2: Create `.sops.yaml` in Ansible directory
```bash
cat > /Users/grahamsmith/Projects/homelab-infra/infra/ansible/.sops.yaml <<EOF
creation_rules:
  - path_regex: inventory/.*\.yml$
    kms: arn:aws:kms:us-west-2:830881980142:key/4a1d5e90-6bf5-41e0-9ece-e50e88fddc0c
EOF
```

### Step 3: Encrypt Ceph credentials
```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/ansible/inventory/wind/group_vars/all/
sops --encrypt --in-place ceph.yml
```

### Step 4: Install sops-ansible plugin (optional, for automatic decryption)
```bash
pip install community.sops
```

Add to playbook requirements or use manual decrypt step.

### Step 5: Test decryption
```bash
sops --decrypt ceph.yml  # Should show plaintext
```

### Step 6: Update documentation
Document SOPS usage in `docs/runbooks/secrets-management.md`

---

## Implementation Plan (if choosing Ansible-Vault)

### Step 1: Create vault password file
```bash
# Store in password manager or secure location
echo "YourSecureVaultPassword123!" > ~/.ansible_vault_pass
chmod 600 ~/.ansible_vault_pass
```

### Step 2: Encrypt Ceph key
```bash
cd /Users/grahamsmith/Projects/homelab-infra/infra/ansible/inventory/wind/group_vars/all/

# Option A: Encrypt entire file
ansible-vault encrypt ceph.yml

# Option B: Encrypt just the sensitive value (recommended)
ansible-vault encrypt_string 'AQBwejhp7lzSBBAAxa8TJhMRakcjYeOgMigqtg==' --name 'ceph_k8s_key' >> ceph.yml.new
# Then manually merge
```

### Step 3: Configure vault password file in Ansible config
```bash
cat >> /Users/grahamsmith/Projects/homelab-infra/infra/ansible/ansible.cfg <<EOF
[defaults]
vault_password_file = ~/.ansible_vault_pass
EOF
```

### Step 4: Test playbook execution
```bash
ansible-playbook -i inventory/wind/inventory.ini --check site.yml
```

### Step 5: Update documentation
Document ansible-vault usage in `docs/runbooks/secrets-management.md`

---

## Decision Log

**Date**: 2025-12-31
**Decision**: [PENDING]
**Rationale**: [To be filled after decision]
**Approved by**: [To be filled]

---

## References

- [SOPS Documentation](https://github.com/mozilla/sops)
- [Ansible-Vault Documentation](https://docs.ansible.com/ansible/latest/user_guide/vault.html)
- [AWS KMS Best Practices](https://docs.aws.amazon.com/kms/latest/developerguide/best-practices.html)
- [Existing .sops.yaml config](../../platform/kubernetes/backups/aws-s3/.sops.yaml)
