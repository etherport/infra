# Mini → AWS via IAM Roles Anywhere (M71 mini-side)

How the **mini** mints short-lived AWS creds from a step-ca X.509 cert — no standing key.
**Prereq:** ✅ the `roles-anywhere` TF stack is **applied** (2026-06-28, the 3 ARNs are filled in
below) and the AWS-side owner-gated steps in [`../planning/archive/m71-roles-anywhere-plan.md`](../planning/archive/m71-roles-anywhere-plan.md)
are resolved (CI has `rolesanywhere:*` via PowerUserAccess; scope = plan/debug-only). **This file is
the only remaining work** — the **mini-local** half (the agent can't reach the mini).

All commands run **on the mini** (macOS, signed into `graham`).

## 0. Reachability check (do first)

The mini (VLAN-202) must reach step-ca's CA API to mint/renew its cert:
```bash
curl -sk https://10.10.201.46:8443/health    # expect {"status":"ok"}
```
If it times out, the M77 standalone-VM firewall (`infra/terraform/proxmox/firewall/standalone-vms.tf`)
only allows `:8443` from the **Servers VLAN (201) + tailnet** — add a VLAN-202→`10.10.201.46:8443`
allow (or use step-ca's tailnet path if it joins the tailnet). A **timeout = firewall**, refused =
service. Don't proceed until `/health` is OK.

## 1. Bootstrap step-ca trust + mint the client cert

```bash
# one-time: trust the step-ca root (fingerprint from `step certificate fingerprint` on the CA)
step ca bootstrap --ca-url https://10.10.201.46:8443 \
  --fingerprint a37b7b1622157ecd6687dc953f95cbb49d152fe9819ed0b54aa56f4f9689cf67

mkdir -p ~/.config/roles-anywhere && chmod 700 ~/.config/roles-anywhere

# mint a leaf X.509 client cert. CN MUST equal var.mini_cert_cn in the TF stack
# (mini.wind.etherport.net) — the role trust policy is scoped to it.
# JWK headless provisioner (jwk_password from SOPS — the mini has the age key):
JWK_PW=$(SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops -d ~/code/infra/infra/ansible/playbooks/secrets/step-ca.sops.yaml | sed -n 's/^jwk_password:[[:space:]]*//p' | tr -d '"')
printf '%s' "$JWK_PW" > /tmp/jwkpw && unset JWK_PW
step ca certificate mini.wind.etherport.net \
  ~/.config/roles-anywhere/cert.pem ~/.config/roles-anywhere/key.pem \
  --provisioner headless --provisioner-password-file /tmp/jwkpw \
  --not-after 24h --force
shred -u /tmp/jwkpw 2>/dev/null || rm -f /tmp/jwkpw
chmod 600 ~/.config/roles-anywhere/key.pem
```
The cert chains step-ca-leaf → intermediate → root; the helper presents leaf+intermediate.

## 2. Install the AWS signing helper

```bash
# AWS RA credential helper (no brew formula — pull the signed binary). The mini is
# Apple Silicon → Aarch64/MacOS/Sonoma; Intel mac → X86_64/MacOS/Sonoma. Pin a current
# version (1.8.4, 2026-06; earlier releases had CVE fixes). NB the path segment is
# MacOS/Sonoma, NOT "Darwin".
curl -fsSL -o /tmp/aws_signing_helper \
  https://rolesanywhere.amazonaws.com/releases/1.8.4/Aarch64/MacOS/Sonoma/aws_signing_helper
sudo install -m 0755 /tmp/aws_signing_helper /usr/local/bin/aws_signing_helper
aws_signing_helper version
```

## 3. Wire `credential_process` (the standing-key replacement)

Add to `~/.aws/config` (NOT `~/.aws/credentials` — no static key):
```ini
[profile homelab-ra]
region = us-west-2
credential_process = /usr/local/bin/aws_signing_helper credential-process \
  --certificate /Users/graham/.config/roles-anywhere/cert.pem \
  --intermediates /Users/graham/.config/roles-anywhere/cert.pem \
  --private-key /Users/graham/.config/roles-anywhere/key.pem \
  --trust-anchor-arn  arn:aws:rolesanywhere:us-west-2:830881980142:trust-anchor/8cdc64d7-332c-4dc3-bf99-0705f92722d6 \
  --profile-arn       arn:aws:rolesanywhere:us-west-2:830881980142:profile/67a6e3cb-8f88-4bc6-8c84-7dd7ac2917ee \
  --role-arn          arn:aws:iam::830881980142:role/wind-mini-roles-anywhere
```
`step ca certificate` writes `cert.pem` as a **bundle** (leaf + step-ca intermediate); the
trust anchor is the step-ca **root**, so the helper must present the intermediate to complete
the chain — hence `--intermediates`. (If validation still fails, split the bundle:
first PEM block → `leaf.pem` for `--certificate`, the rest → `intermediate.pem` for
`--intermediates`.)

Verify:
```bash
aws sts get-caller-identity --profile homelab-ra
# -> arn:aws:sts::830881980142:assumed-role/wind-mini-roles-anywhere/<session>
terraform -chdir=~/code/infra/infra/terraform/aws/<stack> plan   # via AWS_PROFILE=homelab-ra
```

## 4. Cert renewal (launchd timer — like the devbox SSH cert)

The cert is 24h; renew every ~8h so step-ca downtime has slack. Create
`~/Library/LaunchAgents/net.wind.roles-anywhere-renew.plist` running a script that re-mints
the cert (step 1's `step ca certificate …`) on a `StartInterval` of 28800s. Model it on the
devbox `step-ssh-renew.{sh,service,timer}` (`infra/devbox/`). Load:
```bash
launchctl load -w ~/Library/LaunchAgents/net.wind.roles-anywhere-renew.plist
```

## 5. Cut over + remove the standing key

Once `homelab-ra` works for your real TF usage:
```bash
# point existing usage at the RA profile (or rename homelab-ra -> homelab in ~/.aws/config)
# then REMOVE the standing static key from ~/.aws/credentials:
#   delete the [homelab] block (the static access key)   ← the M71 win: zero standing key
```
⚠️ Do **not** delete the `terraform-homelab` IAM *user/key* in AWS (shared local-ops key, H29) —
this only removes the mini's standing key *file*; AWS sessions now come from RA. Keep `[claude-admin]`
out of the file too (interim-win a); pull it from SOPS/laptop only for genuine break-glass.

## Failure modes

- `get-caller-identity` → `AccessDenied` "not authorized to perform sts:AssumeRole": the cert CN
  ≠ `var.mini_cert_cn`, or the role trust policy / trust anchor ARN is wrong. Check
  `step certificate inspect ~/.config/roles-anywhere/cert.pem | grep Subject`.
- `credential_process` errors with cert/chain: the helper needs the FULL chain (leaf+intermediate)
  — `--intermediates` flag or a bundled cert.pem if step-ca didn't include the intermediate.
- Cert expired + step-ca unreachable: break-glass = `[claude-admin]` from SOPS/laptop, fix step-ca,
  re-mint.
