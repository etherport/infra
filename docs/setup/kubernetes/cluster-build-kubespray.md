# Build / Rebuild Kubernetes with Kubespray

> **Where/how to run (2026-07):** kubespray runs **from the devbox** (venv
> `~/.kubespray-venv`). Export `KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert` — the
> wrapper's default key is the dead static key (fleet SSH is cert-only, M76) — and
> run long plays in a **detached tmux** (harness-backgrounded runs get killed).
> Current cluster: **v1.35.0**, containerd 2.2.5, submodule v2.31.0. Read the
> landmines checklist in
> [`../../runbooks/kubernetes-upgrade.md`](../../runbooks/kubernetes-upgrade.md)
> before ANY run.

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
