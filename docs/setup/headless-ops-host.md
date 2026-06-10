# Headless ops host setup (Claude Code Remote Control box)

How to provision a machine to run **Claude Code headless** against this repo —
full `kubectl` / `terraform` / `sops` / `ansible` access — with **no 1Password
dependency at runtime**. Today that machine is the always-on **Mac mini**
(`10.10.202.101`, tailnet `100.79.165.113`); the same procedure applies to the
dev box or any future ops host.

## Why a Mac mini (and not the Linux dev box)

Claude Code's **Remote Control** (drive a session from the phone / desktop app)
needs a subscription login carrying the `user:sessions:claude_code` scope. The
interactive full-scope OAuth login **works on macOS but is broken on headless
Linux** (PKCE `code_challenge` / scope bug, upstream — issues #22398, #43996,
#44531, #45340; nothing fixable on our end). So the mini is the RC host. When
the Linux bug is fixed, the same setup migrates to the dev box and the mini
goes back to being a spare — see [Migration](#migration).

## Design principle: 1Password is for *admin*, not *runtime*

The host needs secrets to do real work (SSH to homelab, decrypt SOPS, reach the
terraform S3 backend). **None of that touches 1Password at runtime.** Everything
comes from two on-disk artifacts:

| Capability        | Source on the host                              | 1P at runtime? |
|-------------------|-------------------------------------------------|----------------|
| SSH to homelab/k8s| `~/.ssh/id_ed25519_homelab` (+ `IdentityAgent none`) | no        |
| GitHub push/sign  | `~/.ssh/id_ed25519_github`                      | no             |
| SOPS decrypt      | age key `~/.config/sops/age/keys.txt`           | no             |
| AWS (tf backend)  | `~/.aws/credentials [homelab]`, rendered from SOPS | no          |
| kubectl           | `~/.kube/config` (admin.conf from k8s-cp1)      | no             |

1Password is touched **once, on an admin machine**, only to *sync secrets into
SOPS* (`scripts/sync-secrets.py`). The headless host then renders everything
from the age key. This is what lets the box run while you're out and can't
unlock 1Password.

## Provisioning steps

### 1. Toolchain (Homebrew)

```bash
brew install node tmux gh sops age kubectl helm awscli ansible
brew install hashicorp/tap/terraform        # license-gated; not in core
npm install -g @anthropic-ai/claude-code     # or: brew install claude (cask/formula)
```

### 2. SSH keys + config

Two keys, by direction (kept off the 1P agent with `IdentityAgent none` so they
work headless):

- `~/.ssh/id_ed25519_homelab` — outbound to PVE / k8s / SBC / standalone VMs.
  Its public half must be in those hosts' `authorized_keys` (it's the homelab
  automation key, `op://Private/xow32nxrvix5ismyupmheyevpe`).
- `~/.ssh/id_ed25519_github` — push + commit signing. Register the **public**
  key on GitHub yourself (browser or `gh ssh-key add`) — agents can't make
  account-security changes.

`~/.ssh/config` managed block (specific hosts **before** any `Host *`, because
SSH is first-match-wins and a `Host *` 1P-agent block otherwise wins):

```
# >>> macmini-rc managed >>>
Host 10.10.* *.wind.etherport.net
    IdentityFile ~/.ssh/id_ed25519_homelab
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking accept-new

Host github.com
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
    IdentityAgent none
# <<< macmini-rc managed <<<
```

Git identity + SSH commit signing:

```bash
git config --global user.name  "Graham Smith"
git config --global user.email "4unsaved_candies@icloud.com"
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_github.pub
```

### 3. SOPS age key

Place the Homelab age private key at `~/.config/sops/age/keys.txt` (mode 600),
and point sops at it for every shell — macOS sops otherwise only looks in
`~/Library/Application Support/sops/age/keys.txt`:

```bash
echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc
```

Verify: `sops -d infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | head`
(recipient `age1fszjt38d2jnw434z3gl6gv66ca79au03j6mgcr7f7f5w05cj85ts06m53g`).

### 4. kubeconfig

kubespray's `admin.conf` points at `https://127.0.0.1:6443`; rewrite it to a
reachable control-plane IP (mirrors `infra/kubespray/post-bootstrap.sh`):

```bash
mkdir -p ~/.kube
ssh -i ~/.ssh/id_ed25519_homelab -o IdentityAgent=none -o IdentitiesOnly=yes \
    ubuntu@10.10.201.50 'sudo cat /etc/kubernetes/admin.conf' \
  | sed 's|https://127.0.0.1:6443|https://10.10.201.50:6443|g' > ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

(No HA VIP — `kube_vip_enabled: false` — so we target k8s-cp1 `10.10.201.50`.)

### 5. AWS credentials (terraform S3 backend) — the durable path

The backend uses `profile = "homelab"` against `terraform.wind.etherport.net`.
Those IAM keys live in 1P item `ojbjsshj45oup6mcu3vlxxb7re` ("AWS Key (Terraform)") and are **also**
baked into the SOPS secret so headless hosts never need `op`:

1. **Admin machine, once** (where 1Password + `op` are signed in — your laptop):
   the manifest already references them
   (`aws_access_key_id` / `aws_secret_access_key` →
   `op://Private/ojbjsshj45oup6mcu3vlxxb7re/{username,password}`).
   Re-bake the SOPS file and commit:
   ```bash
   python3 scripts/sync-secrets.py        # reads op://, re-encrypts homelab-ops.sops.yaml
   git add infra/ansible/playbooks/secrets/homelab-ops.sops.yaml && git commit && git push
   ```
2. **Headless host** (no 1Password): render the profile from SOPS:
   ```bash
   scripts/render-aws-credentials.sh
   AWS_PROFILE=homelab aws sts get-caller-identity   # verify
   ```

### 6. Proxmox provider creds (terraform)

The `proxmox/*` stacks authenticate to PVE with an API token. CI passes it as
`TF_VAR_proxmox_token_{id,secret}`; the headless equivalent injects it from SOPS:

```bash
scripts/tf-proxmox.sh k8s-vms plan   # decrypts the token into terraform's env
```

**Network caveat (the mini specifically):** PVE is a *host* in the **Management/200**
zone (UDM-routed); the mini is on **Clients/202** (switch-routed, zoneless →
Internal transit at the UDM). M56 makes Management *contained*, so mini → PVE
(and other Management hosts) is default-denied. The exception — `Trusted admin
clients (Clients/202) → Management (all)`, scoped to the `trusted-admin-clients`
IP-group (mini + admin laptop) — lives in `infra/ansible/playbooks/udm-firewall.yml`.

The **UDM/Gateway itself** (`10.10.200.1`) *is* reachable from Clients (Clients →
Gateway is allowed — that's why the UDM web UI works from the mini's browser), so
**the mini can apply the playbook headless** — UDM creds come from SOPS
(`udm_tfadmin_user`/`udm_tfadmin_password` → `UDM_USERNAME`/`UDM_PASSWORD` env),
no 1Password:

```bash
export UDM_USERNAME="$(sops -d infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | sed -n 's/^udm_tfadmin_user: *//p'     | tr -d '"')"
export UDM_PASSWORD="$(sops -d infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | sed -n 's/^udm_tfadmin_password: *//p' | tr -d '"')"
ansible-playbook infra/ansible/playbooks/udm-firewall.yml --check   # dry-run / diff
ansible-playbook infra/ansible/playbooks/udm-firewall.yml           # apply
```

Until applied, only Management *hosts* (e.g. PVE `10.10.200.41`) are blocked from
the mini — the Gateway/UDM is not.

### 7. Claude Code Remote Control

```bash
claude --remote-control "macmini"     # then approve / drive from the phone app
```

Wrap it in a tmux session (`~/.local/bin/claude-rc`) so it survives SSH drops.

### 8. Always-on + reachable

```bash
sudo pmset -a disablesleep 1 sleep 0   # no deep sleep; stays reachable
sudo tailscaled install-system-daemon  # Tailscale as a standalone system daemon
```

## Headless verification smoke test

Run **on the host** (proves it works with no 1Password unlock):

```bash
cd ~/code/infra
kubectl get nodes
sops -d infra/ansible/playbooks/secrets/homelab-ops.sops.yaml | head -3
AWS_PROFILE=homelab terraform -chdir=infra/terraform/proxmox/k8s-vms plan -input=false | tail
ping -c2 10.10.201.50
```

## Permissions / autonomy while you're out

Three independent layers — don't conflate them:

- **1Password** = secret access. The host needs **none** at runtime (above).
- **Claude Code permission prompts** = per-action approvals. Answer one-tap from
  the phone via Remote Control, or pre-authorize common actions in
  `.claude/settings.json` (`permissions.allow`) so they run unattended.
- **Auto-mode classifier** = a separate safety gate that can still block
  *production* actions (e.g. SSH into a shared control-plane node) even when a
  permission rule exists. Those need an explicit allow rule or a human decision;
  they will *not* run silently. Plan tasks so anything truly autonomous stays
  inside the allowlisted, non-production set.

## Migration

When the Linux full-scope OAuth bug is fixed, repeat this procedure on the dev
box (steps 1–7 are host-agnostic), move the `claude --remote-control` session
there, and retire the mini. The age key + SSH keys + SOPS render path are
identical; only the host changes.
