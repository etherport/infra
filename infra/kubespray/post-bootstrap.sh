#!/bin/bash
# Post-kubespray bootstrap: Flux + secrets + Velero restore
#
# Runs after kubespray cluster.yml succeeds. Brings the cluster from
# "K8s API is up" to "all workloads restored and operational".
#
# Prerequisites (set as env vars or pass via flags):
#   ANSIBLE_KEY        Path to the SSH private key (homelab automation key)
#                      Used for SCP-ing kubeconfig from k8s-cp1.
#   FLUX_DEPLOY_KEY    Path to the SSH private key for Flux GitOps repo access
#                      (matches the 'flux-system' deploy key on GitHub).
#   SOPS_AGE_KEY_FILE  Path to the age private key (for SOPS decryption).
#   VELERO_BACKUP      Name of the Velero backup to restore from.
#                      Default: pre-migration-20260512-1915.
#
# Usage:
#   ANSIBLE_KEY=/tmp/auto-key \
#   FLUX_DEPLOY_KEY=/tmp/flux-deploy-key \
#   SOPS_AGE_KEY_FILE=~/Library/Application\ Support/sops/age/keys.txt \
#   ./post-bootstrap.sh

set -euo pipefail

: "${ANSIBLE_KEY:?need ANSIBLE_KEY pointing at the homelab automation SSH private key}"
: "${FLUX_DEPLOY_KEY:?need FLUX_DEPLOY_KEY pointing at the Flux deploy SSH private key}"
: "${SOPS_AGE_KEY_FILE:?need SOPS_AGE_KEY_FILE pointing at the age private key}"

CP1_IP="${CP1_IP:-10.10.201.50}"
VELERO_BACKUP="${VELERO_BACKUP:-pre-migration-20260512-1915}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

KUBECONFIG_OUT="/tmp/wind-kubeconfig"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

#-----------------------------------------------------------
log "Step 1/9: Fetching kubeconfig from k8s-cp1..."
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$ANSIBLE_KEY" \
  ubuntu@"$CP1_IP" 'sudo cat /etc/kubernetes/admin.conf' > "$KUBECONFIG_OUT"
sed -i.bak "s|https://127.0.0.1:6443|https://$CP1_IP:6443|g" "$KUBECONFIG_OUT"
rm -f "${KUBECONFIG_OUT}.bak"
chmod 600 "$KUBECONFIG_OUT"
export KUBECONFIG="$KUBECONFIG_OUT"
log "Kubeconfig saved to $KUBECONFIG_OUT"

log "Step 2/9: Verifying cluster API + node readiness..."
kubectl get nodes
for i in $(seq 1 30); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "  ${ready}/${total} nodes Ready"
  if [ "$ready" = "$total" ] && [ "$total" -ge 8 ]; then break; fi
  sleep 10
done

#-----------------------------------------------------------
log "Step 3/9: Creating flux-system namespace..."
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

log "Step 4/9: Creating flux-system Secret (repo deploy key)..."
# Flux's GitRepository expects a known_hosts entry + identity (private SSH key) + identity.pub
ssh-keyscan -t rsa,ed25519 github.com 2>/dev/null > /tmp/gh-known_hosts
ssh-keygen -y -f "$FLUX_DEPLOY_KEY" > /tmp/flux-deploy-key.pub
kubectl create secret generic flux-system \
  --namespace=flux-system \
  --from-file=identity="$FLUX_DEPLOY_KEY" \
  --from-file=identity.pub=/tmp/flux-deploy-key.pub \
  --from-file=known_hosts=/tmp/gh-known_hosts \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/gh-known_hosts /tmp/flux-deploy-key.pub

log "Step 5/9: Creating sops-age Secret (decryption key)..."
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey="$SOPS_AGE_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

#-----------------------------------------------------------
log "Step 6/9: Applying Flux components..."
kubectl apply -f "$REPO_ROOT/clusters/wind/flux-system/gotk-components.yaml"

log "  Waiting for Flux operator pods to be Ready..."
for i in $(seq 1 30); do
  ready=$(kubectl get pods -n flux-system --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ && split($2, a, "/") && a[1]==a[2]' | wc -l | tr -d ' ')
  total=$(kubectl get pods -n flux-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  log "    flux-system pods Ready: ${ready}/${total}"
  if [ "$ready" -ge 4 ] && [ "$total" -ge 4 ]; then break; fi
  sleep 10
done

log "Step 7/9: Applying Flux sync (GitRepository + root Kustomization)..."
kubectl apply -f "$REPO_ROOT/clusters/wind/flux-system/gotk-sync.yaml"

log "  Waiting for Flux to reconcile the root kustomization (this can take 5-10 min)..."
for i in $(seq 1 60); do
  status=$(kubectl get kustomization -n flux-system flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  log "    flux-system kustomization Ready=$status (poll $i)"
  if [ "$status" = "True" ]; then break; fi
  sleep 15
done

#-----------------------------------------------------------
log "Step 8/9: Waiting for Velero to become available..."
for i in $(seq 1 60); do
  if kubectl get deploy -n velero velero --no-headers 2>/dev/null | awk '$4>=1{exit 0} END{exit 1}'; then
    log "    Velero deploy has ready replicas"
    break
  fi
  log "    Velero not ready yet (poll $i)"
  sleep 15
done

# Install velero CLI if not present on this Mac
if ! command -v velero &>/dev/null; then
  log "  Installing velero CLI via brew..."
  brew install velero
fi

log "  Triggering restore from backup: $VELERO_BACKUP"
velero restore create "post-migration-$(date +%Y%m%d-%H%M)" \
  --from-backup "$VELERO_BACKUP" \
  --wait || log "  Velero restore returned non-zero — check 'velero restore describe <name>' for details"

#-----------------------------------------------------------
log "Step 9/9: Scaling WireGuard back up + verifying services..."
kubectl scale deploy -n wireguard wireguard --replicas=1 2>&1 || log "  wireguard deploy not found yet (Flux may not have reconciled)"

log "  Final node + pod state:"
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed' | head -20

log "=== Bootstrap complete ==="
echo
echo "KUBECONFIG=$KUBECONFIG_OUT"
echo "To use: export KUBECONFIG=$KUBECONFIG_OUT"
