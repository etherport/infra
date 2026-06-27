# Terraform: Proxmox K8s VMs

## Location
`infra/terraform/proxmox/k8s-vms/`

State is the **S3 backend** (`terraform.wind.etherport.net`, key
`proxmox/k8s-vms/terraform.tfstate`, S3-native locking `use_lockfile=true`) —
see `backend.tf` and `docs/setup/terraform/remote-state-backend.md`. No local
tfstate.

## Files
- `main.tf`, `variables.tf`, `backend.tf`
- `terraform.tfvars.example` (committed)
- `terraform.tfvars.local` (ignored; rare local-debug only)

## Canonical apply path — GitHub Actions (workflow_dispatch)

TF is **CI-only** (M82): the devbox holds no standing PVE creds. Run the
`terraform-proxmox-k8s-vms.yml` workflow (self-hosted `lifecycle` runner, PVE
token as a GH secret) and pick the action (`plan`/`apply`):

```bash
gh workflow run terraform-proxmox-k8s-vms.yml -f action=plan    # review the diff
gh workflow run terraform-proxmox-k8s-vms.yml -f action=apply   # apply if 0-destroy
```

(The devbox lacks `gh`; dispatch via the Actions:write PAT/API — M92.)

## Rare local-debug only
Re-render the PVE token from SOPS on demand, then it's a throwaway:

```bash
scripts/tf-proxmox.sh k8s-vms plan   # injects TF_VAR_proxmox_token_{id,secret} from SOPS
```

## Notes
- Never commit `terraform.tfvars.local`.
- Cardinal rule: only apply when the plan is `0 to add/change/destroy` (or
  reviewed-and-intended).
