# Git workflow

## What goes in git
- Terraform code (NOT state, NOT tfvars.local)
- Kubespray inventory + group_vars
- Kubernetes manifests + Helm values
- Docs and scripts

## What stays local
- secrets
- kubeconfig artifacts
- terraform.tfstate
- terraform.tfvars.local

## Useful commands
git status
git add .
git commit -m "message"
git push
