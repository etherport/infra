# Cilium breaks after a kubespray run — `/opt/cni/bin` ownership

**TL;DR:** Running kubespray `cluster.yml` (or `--tags=cilium`) chowns `/opt/cni/bin`
to `kube_owner` (**`kube`**), but Cilium's `mount-cgroup` init container needs the dir
**root-owned**. The break is *latent* — existing Cilium agents keep running off loaded
eBPF; it only bites when an agent **restarts** (node reboot, rollout, pod delete), which
then hangs in `Init:CrashLoopBackOff`. **After any kubespray cluster.yml/cilium run,
re-run `pre-flight.yml`** (or chown manually) to restore root ownership.

## Symptom

```
$ kubectl -n kube-system get pods -l k8s-app=cilium
cilium-xxxxx   0/1   Init:CrashLoopBackOff
```
Failing init container = **`mount-cgroup`**:
```
cp: cannot create regular file '/hostbin/cilium-mount': Permission denied
```
Nodes still show `Ready` and old (un-restarted) agents keep working — so it can sit
undetected until the next agent restart.

## Root cause

- `mount-cgroup` runs as **root** with `securityContext.capabilities.drop: [ALL]`
  (no `DAC_OVERRIDE`). Root can therefore only write into `/opt/cni/bin` (mounted as
  `/hostbin`) if root **owns** it.
- The inventory sets **`kube_owner: kube`** (`group_vars/k8s_cluster/k8s-cluster.yml`),
  and kubespray's `roles/kubernetes/preinstall/.../0050-create_directories.yml`
  "Create cni directories" task chowns `/opt/cni/bin` to `{{ kube_owner }}` → `kube`.
- `inventory/pre-flight.yml` deliberately overrides this back to `root:root`, but it is
  **not** run automatically as part of a `cluster.yml`/`--tags=cilium` run.
- A `chown` updates **ctime, not mtime** — so `ls -l` (mtime) can look unchanged while
  ownership flipped today. Check with `stat -c '%U:%G %z' /opt/cni/bin` (ctime).

## Fix / recovery

Restore root ownership on all k8s nodes, then bounce any crashlooping agents:

```bash
# from infra/kubespray/kubespray (venv: ~/.kubespray-venv — see "Running kubespray" below)
~/.kubespray-venv/bin/ansible -i ../inventory/inventory.ini 'kube_control_plane:kube_node' \
  -m file -a 'path=/opt/cni/bin owner=root group=root' \
  -b -u ubuntu --private-key ~/.ssh/id_ed25519_homelab
# (equivalently: re-run pre-flight.yml, which does exactly this)

# verify ALL nodes (don't trust a truncated run — one missed node = one stuck pod):
~/.kubespray-venv/bin/ansible -i ../inventory/inventory.ini 'kube_control_plane:kube_node' \
  -m shell -a 'stat -c "%U:%G" /opt/cni/bin' -b -u ubuntu --private-key ~/.ssh/id_ed25519_homelab

# force crashlooping agents to retry:
kubectl -n kube-system delete pod <crashlooping-cilium-pods>
kubectl -n kube-system rollout status ds/cilium
```

## Prevention

**Always run `pre-flight.yml` AFTER any kubespray `cluster.yml` / `--tags=cilium` run**
(the wrapper does not do this automatically). Open items to make this un-missable:
see `outstanding-work.md` (modernize the stale `kubespray.sh` wrapper to auto-run
pre-flight; evaluate a Cilium chart `DAC_OVERRIDE` on `mount-cgroup` so it tolerates a
`kube`-owned dir; or a per-dir owner override).

## Running kubespray from the mini (the actual, current path)

The committed `kubespray.sh`/`setup.sh` wrappers are **stale** (they expect a venv +
`inventory/wind/` inside the submodule that don't exist). The working invocation:

```bash
git submodule update --init infra/kubespray/kubespray      # v2.30.0
python3 -m venv ~/.kubespray-venv
~/.kubespray-venv/bin/pip install -r infra/kubespray/kubespray/requirements.txt  # ansible 10.7.0 (core 2.17)
cd infra/kubespray/kubespray
~/.kubespray-venv/bin/ansible-playbook -i ../inventory/inventory.ini <playbook> \
  -b -u ubuntu --private-key ~/.ssh/id_ed25519_homelab
```
Note: the system ansible (core 2.21) is too new for kubespray v2.30 — use the venv.
`--tags=cilium` alone fails ("`/tmp/releases/cilium` not found") — the binary download
is in a `download`-tagged play; use `--tags=cilium,download`.
