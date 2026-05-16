# Build / Rebuild Kubernetes with Kubespray

## Repo layout
- Kubespray is a git submodule: `infra/kubespray/kubespray`
- Wrapper scripts: `infra/kubespray/kubespray.sh` and `infra/kubespray/setup.sh`
- Inventory lives in a single file at the kubespray dir root:
  `infra/kubespray/inventory/inventory.ini` (with `group_vars/` and
  `pre-flight.yml` alongside it). The legacy `inventory/wind/` layout
  is no longer used.

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
- `infra/kubespray/inventory/artifacts/admin.conf` (ignored by .gitignore)

Set:
```bash
export KUBECONFIG=$HOME/Projects/homelab-infra/infra/kubespray/inventory/artifacts/admin.conf
```

Verify:
```bash
kubectl get nodes
```
