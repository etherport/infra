#!/usr/bin/env bash
# Kubernetes control-plane CONFIG-invariant assertions — the "cluster-config" drift class.
#
# WHY: these live-cluster settings are defined ONLY in the kubespray inventory, read once
# at component startup, and SILENTLY break security / identity / networking when they drift
# — the exact incidents CLAUDE.md §4-5 warns about (M75 issuer flip -> IRSA + Multus down ~7h;
# cilium policy-audit-mode -> NetworkPolicy enforcement silently off; encryption off). No
# live-vs-IaC diff (terraform plan / ansible --check) covers them, and a kubespray run only
# RE-asserts them — between runs (or after a hand-edit / helm upgrade) the live values can drift.
#
# Needs kubectl access (KUBECONFIG). Reads LIVE values, asserts == the EXPECTED invariants
# (encoded below, sourced from the kubespray inventory — keep in sync). Exits non-zero + lists
# every failure on drift; prints PASS lines on success.
set -uo pipefail

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# ---- EXPECTED invariants. Source of truth = the kubespray inventory; update here only when
#      you DELIBERATELY change the inventory (a reviewed change), same as the topology detector.
# infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml:32
EXP_ISSUER="https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com"
# M75: --api-audiences MUST pin sts.amazonaws.com — else it defaults to the issuer and 401s
# every in-cluster projected token (IRSA + serviceaccount auth).
EXP_AUD_SUBSTR="sts.amazonaws.com"
# infra/kubespray/inventory/group_vars/k8s_cluster/k8s-net-cilium.yml:172 / :116 / :120
EXP_POLICY_AUDIT="false"   # enforce (NOT audit) — H3 NetworkPolicy tiers depend on this
EXP_WIREGUARD="true"       # M66 east-west pod-to-pod encryption ON

# ---- apiserver flags on EVERY control plane (a drift on one CP is still a real break) ----
for cp in k8s-cp1 k8s-cp2 k8s-cp3; do
  # Render the command array one arg per line (the flags live in .command for kubeadm static pods).
  cmd="$(kubectl get pod -n kube-system "kube-apiserver-$cp" -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}' 2>/dev/null)"
  if [ -z "$cmd" ]; then bad "apiserver $cp: pod not found / unreadable"; continue; fi
  iss="$(printf '%s\n' "$cmd" | grep -E '^--service-account-issuer=' | head -1 | cut -d= -f2-)"
  aud="$(printf '%s\n' "$cmd" | grep -E '^--api-audiences=' | head -1 | cut -d= -f2-)"
  [ "$iss" = "$EXP_ISSUER" ] && ok "$cp --service-account-issuer" \
    || bad "$cp --service-account-issuer = '${iss:-<none>}' (expected $EXP_ISSUER) -> IRSA + Multus BREAK"
  case "$aud" in
    *"$EXP_AUD_SUBSTR"*) ok "$cp --api-audiences pins $EXP_AUD_SUBSTR" ;;
    *) bad "$cp --api-audiences = '${aud:-<none>}' (must include $EXP_AUD_SUBSTR) -> in-cluster tokens 401" ;;
  esac
done

# ---- Cilium dataplane invariants (cilium-config ConfigMap) ----
pa="$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.policy-audit-mode}' 2>/dev/null)"
wg="$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-wireguard}' 2>/dev/null)"
[ "$pa" = "$EXP_POLICY_AUDIT" ] && ok "cilium policy-audit-mode=$pa (enforce)" \
  || bad "cilium policy-audit-mode='${pa:-<none>}' (expected $EXP_POLICY_AUDIT) -> NetworkPolicy ENFORCEMENT OFF"
[ "$wg" = "$EXP_WIREGUARD" ] && ok "cilium enable-wireguard=$wg (encryption on)" \
  || bad "cilium enable-wireguard='${wg:-<none>}' (expected $EXP_WIREGUARD) -> east-west encryption OFF"

# NB the cilium-config + apiserver flags are read at STARTUP — a drifted value may not bite until
# the next pod restart, and both NetworkPolicy and IRSA fail SILENTLY. That latency is exactly why
# this assertion exists.
# TODO v1.1: assert /opt/cni/bin owner == root:root on each node (the kubespray cni-dir gotcha that
# CrashLoops Cilium on next restart) — needs node-FS access (a privileged DaemonSet/Job probe).

if [ "$fail" -ne 0 ]; then
  echo ""
  echo "CLUSTER-CONFIG DRIFT: a live control-plane invariant diverged from the kubespray IaC."
  echo "See CLAUDE.md §4-5 + infra/kubespray/inventory/group_vars/k8s_cluster/. If the change was"
  echo "intentional, update the kubespray inventory AND the EXPECTED constants in this script."
fi
exit "$fail"
