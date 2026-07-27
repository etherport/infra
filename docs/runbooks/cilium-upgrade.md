# Runbook — upgrading Cilium (Helm-managed, from the devbox)

**TL;DR:** Cilium is a **Helm release** (`cilium`/kube-system), **NOT** Flux- or
kubespray-managed for its lifecycle. Upgrade with `helm upgrade` **from the devbox**
(`helm` v3.19 in `~/.local/bin`), then re-assert every hand-patched value that isn't in
the stored Helm values (especially **`policyAuditMode`**), rollout-restart, and verify
enforce-mode / WireGuard / BGP / 0-drops. Persist the new version in the kubespray
inventory so a future kubespray run doesn't fight it. **Never upgrade Cilium via
kubespray** ([[cilium-cni-dir-owner]] landmine).

---

## Why this runbook exists

The 2026-07-02 patch of 1.18.6→1.18.11 (CVE-2026-49445) nearly **silently
un-enforced all 6 NetworkPolicy tiers**. `helm upgrade --reuse-values` threw a
template nil-pointer (`hubble.relay.logOptions.format`), so the fallback
`--reset-then-reuse-values` was used — but the **stored Helm values had drifted from
the live `cilium-config` ConfigMap** (audit mode was toggled OFF via a ConfigMap
hand-patch during the H3 rollout, never written back to Helm values). A
reset-then-reuse re-materialised `policyAuditMode=true`. It was caught in the
post-upgrade verify, not before. This runbook bakes in the re-assert + verify steps
so it can't happen silently again.

## Preconditions

- Run from the **devbox** (`helm`, `kubectl` cluster-admin, `sops`+age all present).
- Confirm the target version fixes the CVE and check the Cilium upgrade notes for that
  minor for any `values` migrations or `cilium-cli` preflight requirements.
- Snapshot the current live values first (this is your rollback reference):
  ```bash
  helm -n kube-system get values cilium > /tmp/cilium-values-pre.yaml
  # compare against the committed snapshot to spot drift BEFORE you start:
  diff /tmp/cilium-values-pre.yaml docs/reference/snapshots/cilium-helm-values.yaml
  ```
- Record the durable truth of the hand-patched knobs (these live in the ConfigMap, may
  differ from Helm values):
  ```bash
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg config | \
    grep -iE 'policy-audit|enable-ipv4-egress-gateway|enable-wireguard'
  ```

## Upgrade

```bash
export PATH="$HOME/.local/bin:$PATH"
helm repo update cilium

# Patch/minor within the same major. Try --reuse-values first; if it throws a
# template error (some chart minors changed value paths), fall back to
# --reset-then-reuse-values AND re-assert the hand-patched knobs on the SAME line.
helm upgrade cilium cilium/cilium -n kube-system \
  --version <TARGET> \
  --reuse-values \
  --set policyAuditMode=false          # re-assert: NOT in stored values, MUST be off
# if the above errors on a nil template value:
# helm upgrade cilium cilium/cilium -n kube-system --version <TARGET> \
#   --reset-then-reuse-values --set policyAuditMode=false <+ any other drifted knobs>

kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status  ds/cilium --timeout=5m
```

> ⚠️ **The `policyAuditMode` re-assert is mandatory** whenever you use
> `--reset-then-reuse-values`. Cilium reads policy-audit only at agent startup, so the
> rollout restart is what actually applies (or mis-applies) it. If audit flips back on,
> every enforced tier goes fail-open with no alert.

## Verify (all four — a drop at any one is a silent regression)

```bash
# 1. Enforce mode ON (audit OFF) on every agent:
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg config | grep -i policy-audit
#    want: PolicyAuditMode  Disabled

# 2. WireGuard encryption still on:
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
#    want: Encryption: Wireguard ... (a non-zero key)

# 3. MetalLB BGP sessions all up (FRR mode, L24):
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -i bgp   # if BGP CP on
#    plus the UDM side / metallb_bgp_session_up metric = 8/8

# 4. Version + agent health across all nodes:
kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n kube-system get pods -l k8s-app=cilium -o wide     # all Running, none Init:*
# and: 0 unexpected drops in Hubble/Loki {job="hubble-audit"} for a few minutes
```

## Persist + document (a change isn't done until this is done)

1. **kubespray inventory** — set the version so a future kubespray run matches, not
   fights:
   `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-net-cilium.yml` →
   `cilium_version: "<TARGET>"`.
2. **Refresh the values snapshot** (the durable record of hand-patched truth):
   `helm -n kube-system get values cilium > docs/reference/snapshots/cilium-helm-values.yaml`
3. Commit both + a session-log entry noting the CVE and any drift you caught.

## Rollback

`helm rollback cilium <PREV_REVISION> -n kube-system` (`helm history cilium -n kube-system`)
then `rollout restart ds/cilium` + the same 4-point verify. Re-assert `policyAuditMode=false`
if the rolled-back revision predates a ConfigMap hand-patch.

## See also

- [[cilium-cni-dir-owner]] — **never** upgrade Cilium via kubespray (the `/opt/cni/bin`
  chown landmine); this is why Cilium is Helm-managed out-of-band.
- `docs/runbooks/networkpolicy-tiers.md` — the labeled tiers (14 as of 2026-07-27) + the
  audit-toggle procedure (what audit mode gates).
- `docs/reference/snapshots/cilium-helm-values.yaml` — the committed values snapshot.
