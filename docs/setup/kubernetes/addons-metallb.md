# MetalLB

> **Mode = BGP (not L2), Flux-managed.** MetalLB peers with the UDM over eBGP (peer
> `10.10.201.1`, ASN 64512) and advertises the VIP /32s; there is no `L2Advertisement`
> (M18/M36, 2026-05-31). Raw ICMP to a VIP fails by design; TCP works. The manifest is
> reconciled by **Flux** — the `kubectl apply` below is for break-glass/initial bring-up
> only, not the normal change path (commit to git). Detail:
> `platform/kubernetes/metallb/README.md` + `docs/runbooks/bgp-phase-{a,b,c}.md`.

## Purpose
Provides LoadBalancer IPs in a bare-metal cluster (no cloud LB).

## Where files live
platform/kubernetes/metallb/metallb-wind.yaml

## Apply
kubectl apply -f platform/kubernetes/metallb/metallb-wind.yaml

## Verify
kubectl get pods -n metallb-system -o wide
kubectl get svc -A | grep LoadBalancer
