# Terraform: Proxmox K8s VMs

## Location
infra/terraform/proxmox/k8s-vms/

## Files
- main.tf
- variables.tf
- terraform.tfvars.example (committed)
- terraform.tfvars.local (ignored; local only)
- terraform.tfstate* (ignored; local only unless you move to remote backend)

## Standard commands
cd infra/terraform/proxmox/k8s-vms
terraform init
terraform plan  -var-file=terraform.tfvars.local
terraform apply -var-file=terraform.tfvars.local
terraform destroy -var-file=terraform.tfvars.local

## Notes
- Do not commit tfstate or tfvars.local
- Consider remote state later (S3, etc.) if you want team-safe workflows
