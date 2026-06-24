# tetragon — eBPF runtime security / detection (M74)

Cilium **Tetragon** — kernel-level (eBPF) observability + the "assume-breach" detection
layer: see what a *compromised running pod* actually does (exec, file access, network,
capability use) that admission (PSA/Kyverno) and network policy (H3) can't.

The **engine** is a Flux HelmRelease
([`clusters/wind/helm-releases/tetragon.yaml`](../../../clusters/wind/helm-releases/tetragon.yaml),
chart 1.7.x, from the existing `cilium` helm repo). **Observe-only — no enforcement/kill.**
This directory will hold the **TracingPolicies** (the detections) in v2.

## Status

**v1 (2026-06-24) — agent deployed, stdout export OFF.** The eBPF sensors are loaded on every
node; events are viewable **on demand** via the gRPC API:
```bash
kubectl exec -n tetragon ds/tetragon -c tetragon -- tetra getevents -o compact
```
Export to stdout is **disabled on purpose**: Alloy tails *all* pod logs into the single-binary
Loki, so a naive Tetragon firehose (every process exec, cluster-wide) would flood it. v1
therefore takes zero Loki risk.

> **Gotcha (chart 1.7):** the disable key is **`export.mode: ""`** (empty string = no
> sidecar), **not** `export.stdout.enabled`. There is no such flag — Helm silently drops
> unknown values, so the wrong path leaves the chart default (`export.mode: "stdout"`) active
> and the `export-stdout` sidecar runs the full firehose (~800 process_exec/exit lines/min
> cluster-wide → ~1.1M/day into Loki). Verify after any change: the DaemonSet pods should be
> **1/1** (just `tetragon`), not 2/2 — a second `export-stdout` container means export is ON.

## v2 (planned) — the detection pipeline

1. **TracingPolicies** here (start high-signal, low-volume): e.g. write to `/etc/shadow` //
   `/etc/sudoers` // `~/.ssh/authorized_keys` (persistence/cred-theft), a shell spawned inside a
   container, unexpected privileged syscalls. (Tetragon kprobe/`PROCESS_KPROBE` events.)
2. **Selective export** so only those matter: enable `export.stdout` **with**
   `tetragon.exportDenyList` dropping `{"event_set":["PROCESS_EXEC","PROCESS_EXIT"]}` (the
   firehose) + health checks → only TracingPolicy-matched events flow → Alloy → Loki. Low volume.
3. **Alert:** a loki-ruler rule on `{namespace="tetragon"}` matched-event lines (mirrors the
   Cilium hubble-audit alert pattern in `06-loki-rules-cilium-audit.yaml`).
4. (Optional, later) **enforcement mode** on specific policies (Tetragon can *kill* on match) —
   only after the audit/observe phase is trusted.

Until v2, Tetragon is a forensics tool you reach for on demand, not a continuous alert source.
