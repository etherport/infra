# Build / Rebuild Kubernetes with Kubespray

## Repo layout
- Kubespray is a git submodule: `infra/ansible/kubespray`
- Your inventory lives outside the submodule:
  `infra/ansible/inventory/wind/inventory.ini`
  `infra/ansible/inventory/wind/group_vars/...`

## Run Kubespray
cd infra/ansible/kubespray
ansible-playbook -i ../inventory/wind/inventory.ini cluster.yml -b

## Upgrade (example)
cd infra/ansible/kubespray
ansible-playbook -i ../inventory/wind/inventory.ini upgrade-cluster.yml -b

## Kubeconfig on your Mac
Preferred: store kubeconfig in repo *ignored* artifacts directory:
- `infra/ansible/inventory/wind/artifacts/admin.conf`  (ignored by .gitignore)

Set:
export KUBECONFIG=$HOME/Projects/homelab-infra/infra/ansible/inventory/wind/artifacts/admin.conf

Verify:
kubectl get nodes
