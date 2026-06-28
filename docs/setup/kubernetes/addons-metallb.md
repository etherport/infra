# MetalLB

> **Mode = BGP (not L2), FRR engine, Helm/Flux-managed.** The MetalLB engine runs in
> **FRR mode** (`speaker.frr.enabled=true`) from the **HelmRelease**
> `clusters/wind/helm-releases/metallb.yaml` (speaker DS carries the frr/reloader/
> frr-metrics sidecars); the native kubespray addon is disabled (`metallb_enabled: false`).
> Speakers peer with the UDM over eBGP (myASN 64513 ↔ peerASN 64512 @ `10.10.201.1`) with
> **TCP-MD5** on the session (BGPPeer `spec.passwordSecret` → `bgp-md5`) and advertise the
> VIP /32s; there is no `L2Advertisement` (M18/M36, 2026-05-31). Raw ICMP to a VIP fails by
> design; TCP works. The engine ships via the **HelmRelease**; the **CRs + MD5 secret** are
> reconciled by **Flux** via the kustomization — committing to git is the normal change path
> (a bare `kubectl apply -f metallb-wind.yaml` installs neither the engine nor the MD5 secret).
> Detail: `platform/kubernetes/metallb/README.md` +
> `docs/runbooks/archive/bgp-phase-{a,b,c}-*.md`.

## Purpose
Provides LoadBalancer IPs in a bare-metal cluster (no cloud LB).

## Where files live
clusters/wind/helm-releases/metallb.yaml          # FRR-mode engine (HelmRelease)
platform/kubernetes/metallb/metallb-wind.yaml     # CRs: IPAddressPool/BGPPeer/BGPAdvertisement
platform/kubernetes/metallb/02-bgp-md5-secret.sops.yaml   # TCP-MD5 key (SOPS)
platform/kubernetes/metallb/kustomization.yaml    # ties the CRs + MD5 secret together

## Apply
# Engine: ships via the HelmRelease (Flux installs/upgrades the FRR-mode controller+speaker).
# CRs + MD5 secret: reconciled by Flux from the kustomization — commit to git is the change path.
# A bare `kubectl apply -f metallb-wind.yaml` does NOT install the engine and skips the MD5 secret.

## Verify
kubectl get pods -n metallb-system -o wide
kubectl get svc -A | grep LoadBalancer
