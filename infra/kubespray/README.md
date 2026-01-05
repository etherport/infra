# Kubespray Configuration

This directory contains the Kubernetes cluster inventory for use with [Kubespray](https://github.com/kubernetes-sigs/kubespray).

## Directory Structure

```
kubespray/
├── inventory/              # Cluster inventory (tracked in git)
│   ├── group_vars/         # Variable definitions
│   │   ├── all/            # Global variables
│   │   └── k8s_cluster/    # Cluster-specific variables
│   ├── inventory.ini       # Host definitions
│   └── pre-flight.yml      # Pre-flight checks
└── README.md
```

## Setup

Kubespray is cloned separately (not stored in this repo) and uses this inventory.

### Initial Setup

```bash
# Clone kubespray
git clone https://github.com/kubernetes-sigs/kubespray.git ~/kubespray
cd ~/kubespray

# Create virtual environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Symlink this inventory
ln -sf ~/Projects/homelab-infra/infra/kubespray/inventory ~/kubespray/inventory/wind
```

### Running Playbooks

```bash
cd ~/kubespray
source venv/bin/activate

# Deploy cluster
ansible-playbook -i inventory/wind/inventory.ini cluster.yml --become

# Upgrade cluster
ansible-playbook -i inventory/wind/inventory.ini upgrade-cluster.yml --become

# Scale cluster (add nodes)
ansible-playbook -i inventory/wind/inventory.ini scale.yml --become

# Remove node
ansible-playbook -i inventory/wind/inventory.ini remove-node.yml --become -e node=<node-name>
```

## Current Cluster

| Node | Role | IP |
|------|------|-----|
| k8s-cp1 | control-plane | 10.10.201.50 |
| k8s-w1 | worker | 10.10.201.51 |
| k8s-w2 | worker | 10.10.201.52 |
| k8s-w3 | worker | 10.10.201.53 |
| k8s-gpu1 | worker (GPU) | 10.10.201.60 |

## Key Configuration

| Setting | Value | File |
|---------|-------|------|
| Kubernetes version | v1.33.7 | `group_vars/k8s_cluster/k8s-cluster.yml` |
| Container runtime | containerd | `group_vars/all/containerd.yml` |
| Network plugin | Calico | `group_vars/k8s_cluster/k8s-cluster.yml` |
| Pod CIDR | 10.233.64.0/18 | `group_vars/k8s_cluster/k8s-cluster.yml` |
| Service CIDR | 10.233.0.0/18 | `group_vars/k8s_cluster/k8s-cluster.yml` |

## Sensitive Files (Not in Git)

After running kubespray, these files are generated but gitignored:

- `inventory/artifacts/admin.conf` - Kubernetes admin kubeconfig
- `inventory/credentials/` - Certificate keys

To retrieve admin.conf after cluster creation:
```bash
scp graham@k8s-cp1:/etc/kubernetes/admin.conf ~/.kube/config
```

## Related Documentation

- [Kubernetes Upgrade Procedures](../../docs/runbooks/kubernetes-upgrade.md)
- [Disaster Recovery](../../docs/runbooks/disaster-recovery.md)
- [Node Updates](../../docs/NODE-UPDATES.md)
