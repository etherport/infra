# Build / Rebuild Kubernetes with Kubespray

## Repo layout
- Kubespray is a git submodule: `infra/kubespray/kubespray`
- Wrapper scripts: `infra/kubespray/kubespray.sh` and `infra/kubespray/setup.sh`
- Your inventory lives in: `infra/kubespray/inventory/wind/`

## First-time Setup

```bash
cd ~/Projects/homelab-infra/infra/kubespray
./setup.sh
```

This initializes the submodule, creates a Python venv, installs dependencies, and symlinks the inventory.

## Run Kubespray

```bash
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh cluster.yml
```

## Upgrade (example)

```bash
cd ~/Projects/homelab-infra/infra/kubespray
./kubespray.sh upgrade-cluster.yml
```

## Kubeconfig on your Mac

Preferred: store kubeconfig in repo *ignored* artifacts directory:
- `infra/kubespray/inventory/wind/artifacts/admin.conf` (ignored by .gitignore)

Set:
```bash
export KUBECONFIG=$HOME/Projects/homelab-infra/infra/kubespray/inventory/wind/artifacts/admin.conf
```

Verify:
```bash
kubectl get nodes
```
