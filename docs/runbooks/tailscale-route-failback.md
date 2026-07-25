# Tailscale /19 break-glass + failback — when the K8s subnet router is down

**Model (M149/M150, 2026-07-25):** the K8s Connector (`k8s-homelab-router`) is the **sole**
`10.10.192.0/19` advertiser. There is **no automatic TS failover** — the control plane's
primary election preempts on every advertiser change (fixed preference
`vpn-aws > vpn-fallback > k8s-homelab-router`, no failback), so a standby advertising the
`/19` steals routing even when the K8s router is healthy. Automatic backup remote access is
the **WireGuard VIP** (`10.10.201.20` via UDM `:9821`, keepalived) — prefer it before
touching TS routes. Background: `docs/architecture/vpn-tailscale.md` (sole-advertiser
section), tracker M149/M150.

## Symptoms that the K8s router is down

- TS clients can't reach any `10.10.x` homelab IP (tailnet-service nodes like
  `plex.tail48f596.ts.net` may still work — they're separate proxies).
- `tailscale-route-drift` CI detector red: `k8s-homelab-router lastSeen … offline?`
- `kubectl -n tailscale get pod ts-homelab-subnet-router-*` not Running (if the cluster
  is reachable another way).

## Decision

1. **Cluster up, only the router pod broken** → fix the pod (delete it; the operator
   recreates). No route changes needed.
2. **Cluster down / unreachable, need TS access to the LAN** → break-glass below.
3. **Just need remote access, WG works** → use the WG profile and stop here.

## Break-glass: advertise the /19 from vpn-fallback

On `vpn-fallback` (10.10.201.15 — via WG, or PVE console if nothing routes):

```bash
sudo tailscale set --advertise-routes=10.10.192.0/19
```

Route approval persists per node+route in the tailnet, so it activates immediately —
no admin-console step.

**Limits while on break-glass:** vpn-fallback is a VLAN-201 host → it **cannot reach the
MetalLB BGP VIPs** (`10.10.201.70` Traefik, `10.10.201.5` DNS) — no `*.wind` ingress or
`.5` DNS through this path. Direct host IPs and SSH work. DNS: use `10.10.201.6`
(dns-fallback VM) or `10.10.100.10`.

## Failback (MANDATORY once the K8s router is healthy)

The election will NOT hand routing back on its own — vpn-fallback keeps the primary while
it advertises. Once `kubectl -n tailscale get pod ts-homelab-subnet-router-*` is Running:

```bash
# on vpn-fallback — drop the advert; the K8s router (sole advertiser again) takes primary
sudo tailscale set --advertise-routes=
```

Verify from any cluster host:

```bash
kubectl -n tailscale exec <ts-homelab-subnet-router-pod> -- tailscale status --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["PrimaryRoutes"])'
# expect: ['10.10.192.0/19']
```

or wait for the next `tailscale-route-drift` run (≤6h) to go green / auto-close its issue.

## Never do

- **Never leave the vpn-fallback advert up "as a warm standby"** — it holds the primary
  and blackholes the VIPs for every TS client (the exact 2026-07 failure class).
- **Never add the /19 to vpn-aws** (`tailscale.yml` or console) — silent AWS hairpin for
  all TS clients.
- **Never reinstall the retired `tailscale-failover` unit** — auto-failover is unsafe
  under preemptive election; `playbooks/tailscale.yml` now removes it by design.
