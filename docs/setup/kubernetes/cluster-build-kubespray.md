# Build / Rebuild Kubernetes with Kubespray

## Repo layout
- Kubespray is a git submodule: `infra/kubespray/kubespray`
- Wrapper scripts: `infra/kubespray/kubespray.sh` and `infra/kubespray/setup.sh`
- Inventory: `infra/kubespray/inventory/inventory.ini` is a symlink to
  `../../ansible/inventory/wind/inventory.ini` (the single shared homelab
  inventory; standalone-VM hosts are ignored by the `k8s_cluster` group), with
  `group_vars/` and `pre-flight.yml` alongside it. The `inventory/wind/` dir is
  still present and holds `credentials/kubeadm_certificate_key.sops.yaml`.

## First-time Setup

```bash
cd infra/kubespray
./setup.sh
```

This initializes the submodule, creates a Python venv, installs dependencies, and symlinks the inventory.

## Run Kubespray

```bash
cd infra/kubespray
./kubespray.sh cluster.yml
```

## Upgrade (example)

```bash
cd infra/kubespray
./kubespray.sh upgrade-cluster.yml
```

## Kubeconfig

Preferred: store kubeconfig in repo *ignored* artifacts directory:
- `infra/kubespray/inventory/artifacts/admin.conf` (ignored by .gitignore)

Set (path relative to the repo root):
```bash
export KUBECONFIG="$PWD/infra/kubespray/inventory/artifacts/admin.conf"
```

Verify:
```bash
kubectl get nodes
```
