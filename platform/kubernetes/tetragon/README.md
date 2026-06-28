# tetragon — eBPF runtime security / detection (M74)

Cilium **Tetragon** — kernel-level (eBPF) observability + the "assume-breach" detection
layer: see what a *compromised running pod* actually does (exec, file access, network,
capability use) that admission (PSA/Kyverno) and network policy (H3) can't.

The **engine** is a Flux HelmRelease
([`clusters/wind/helm-releases/tetragon.yaml`](../../../clusters/wind/helm-releases/tetragon.yaml),
chart 1.7.x, from the existing `cilium` helm repo). **Observe-only — no enforcement/kill.**
This directory will hold the **TracingPolicies** (the detections) in v2.

## Status

**v2 (2026-06-28) — LIVE: selective export + alerting (see below).** 2 TracingPolicies detect
high-signal events → selective Loki export (firehose excluded) → 2 loki-ruler alerts. Still
observe-only. Verified e2e (policy match → export → all alert field-paths resolve → ruler loaded).

**v1 (2026-06-24) — agent deployed, stdout export OFF (superseded by v2).** The eBPF sensors are
loaded on every node; events are also viewable **on demand** via the gRPC API:
```bash
kubectl exec -n tetragon ds/tetragon -c tetragon -- tetra getevents -o compact
```
Export to stdout is **disabled on purpose**: Alloy tails *all* pod logs into the single-binary
Loki, so a naive Tetragon firehose (every process exec, cluster-wide) would flood it. v1
therefore takes zero Loki risk.

> **Gotcha (chart 1.7) — version-dependent:** `export.mode` toggles the stdout export
> sidecar: `""` = OFF (v1), `"stdout"` = ON (v2). There is **no** `export.stdout.enabled`
> flag — Helm silently drops unknown values, so a wrong key leaves the chart default active.
> **In v1, 1/1 pods (just `tetragon`) meant export OFF. In v2, pods are 2/2 (`tetragon` +
> `export-stdout`) and that is CORRECT** — the second container = export ON. Volume safety in
> v2 comes from the ALLOWLIST (below), **not** the sidecar's absence — do not "fix" 2/2 → 1/1.

## v2 (LIVE 2026-06-28) — the detection pipeline

All four pieces are implemented + verified e2e. Tetragon is now a **continuous alert source**
for high-signal runtime events, still **observe-only** (`monitor_only`, no kill).

1. **TracingPolicies** (`./`, cluster-scoped, observe-only):
   - **`10-tp-cred-file-access.yaml`** (`detect-cred-file-access`) — `security_file_permission`
     + `security_path_truncate` kprobes, narrowed from the upstream `filename_monitoring.yaml`
     example's broad `/etc/` to credential/persistence files only: `/etc/shadow`, `/etc/gshadow`,
     `/etc/sudoers*` (Prefix), `*/.ssh/authorized_keys` (Postfix). A container touching these = cred
     theft / backdoor.
   - **`11-tp-setuid-root.yaml`** (`detect-setuid-root`) — `sys_setuid` kprobe filtered to `uid==0`
     (escalate to root). "Unexpected privileged syscall."
   - **`12-tp-ptrace-inject.yaml`** (`detect-ptrace-inject`) — `sys_ptrace` filtered to
     `PTRACE_ATTACH`/`PTRACE_SEIZE` (attach to ANOTHER process = injection / live cred-dump).
     Self-trace (`TRACEME`) excluded. NPOST=0 in practice.
   - **`13-tp-pivot-root.yaml`** (`detect-pivot-root`) — `sys_pivot_root` from a non-init
     (`matchPIDs NotIn` ns-pid 0/1) process = container breakout. runc's host-ns setup pivot is
     export-filtered. NPOST=0 in practice.
2. **Selective export** (`clusters/wind/helm-releases/tetragon.yaml`): `export.mode: stdout`
   **with `tetragon.exportAllowList` restricted to
   `{"event_set":["PROCESS_KPROBE","PROCESS_TRACEPOINT","PROCESS_UPROBE","PROCESS_LSM"]}`** — the
   `PROCESS_EXEC/EXIT` firehose is NOT in the allowlist so it never flows. `exportDenyList` keeps the
   chart-default health-check + namespace `["","cilium","kube-system"]` drops. **Measured steady-state
   export volume: 0 lines/min** (only real policy matches in POD namespaces flow). NB: runc's
   container-setup `setuid(0)` is **host-ns** → caught by the namespace denylist, so it does NOT
   export (its kprobe NPOST counter still ticks — that's pre-export-filter; ignore it).
3. **Alert** (`platform/kubernetes/monitoring/11-loki-rules-tetragon.yaml`): two loki-ruler rules off
   `{namespace="tetragon", container="export-stdout"}` (Alloy tails the sidecar's pod log) — parsing
   `process_kprobe.{policy_name,function_name,process.binary,process.pod.{namespace,name}}`:
   **`TetragonCredFileAccess`** (critical, `for:0m`) + **`TetragonSetuidRoot`** (warning, `for:5m`)
   + **`TetragonPtraceInject`** (critical) + **`TetragonPivotRoot`** (critical). Verified: a triggered
   `/etc/shadow` read exported with all field-paths resolving; the rules-sidecar loaded `tetragon.yaml`
   into the ruler.
4. **(Deferred) enforcement mode** — Tetragon can `kill`/`override` on match; left for after the
   observe phase is trusted (would add `matchActions` to a policy).

### Deferred / follow-ups
- **Shell-in-container** detection (the README's original 3rd example) is **not** in this v2: a clean
  shell-exec signal is naturally a `PROCESS_EXEC` event, which the selective-export allowlist
  deliberately drops. Doing it without re-opening the exec firehose needs a kprobe/tracepoint-on-execve
  approach (emitting `PROCESS_KPROBE`) — a separate policy. Tracked for v2.1.
- **More privileged syscalls** — ✅ `sys_ptrace` + `sys_pivot_root` added (2026-06-28). Further
  low-false-positive candidates if wanted: kernel-module load (`finit_module`), `sys_mount` (but
  mount is noisier — CSI plugins mount; would need binary exclusions).
- **Tuning** — if `detect-setuid-root` is noisy from a known `su-exec`/`gosu` entrypoint, add a
  `matchBinaries` `NotIn` exclusion to `11-tp-setuid-root.yaml`.
