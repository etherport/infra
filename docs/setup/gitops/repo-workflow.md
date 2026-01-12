# Git Repository Workflow

Guidelines for what belongs in version control and repository best practices.

## What Goes in Git

| Category | Examples |
|----------|----------|
| Terraform code | `*.tf` files (NOT state, NOT tfvars.local) |
| Ansible | Kubespray inventory, group_vars |
| Kubernetes | Manifests, Helm values, Kustomize overlays |
| Documentation | Markdown files, diagrams |
| Scripts | Automation scripts, utilities |

## What Stays Local

| Category | Examples | Reason |
|----------|----------|--------|
| Secrets | API keys, passwords, certificates | Security |
| Kubeconfig | `~/.kube/config`, cluster credentials | Security |
| Terraform state | `terraform.tfstate`, `*.tfstate.backup` | Contains secrets, use remote backend |
| Local overrides | `terraform.tfvars.local` | Machine-specific |

## Common Commands

```bash
# Check repository status
git status

# Stage all changes
git add .

# Commit with message
git commit -m "descriptive message"

# Push to remote
git push

# Pull latest changes
git pull

# Create feature branch
git checkout -b feature/my-feature
```

## Commit Message Guidelines

Use clear, descriptive commit messages:

```bash
# Good examples
git commit -m "Add GPU worker node to Terraform configuration"
git commit -m "Fix MetalLB IP range in Helm values"
git commit -m "Update monitoring dashboards for new metrics"

# Avoid
git commit -m "update"
git commit -m "fix stuff"
```

## Related Documentation

- [GitOps with Flux](./flux-overview.md)
- [Making Changes](./making-changes.md)
