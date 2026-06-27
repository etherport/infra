# Traefik Ingress

## Purpose
- Ingress controller for cluster services (HelmRelease, HA `replicas: 2`)
- TLS via cert-manager wildcard `*.wind.etherport.net` + Traefik default
  `TLSStore` (no embedded ACME on Traefik itself; DNS-01 is via Cloudflare
  since the 2026-05-27 migration off Route53)
- Can proxy non-k8s services too (UPS/PDU/Proxmox web UIs)

## Where files live

- `clusters/wind/helm-releases/traefik.yaml` — the Flux HelmRelease
- `platform/kubernetes/traefik/`
  - `traefik-values.yaml` — Helm values (no PVC, no ACME)
  - `clusterissuer-letsencrypt.yaml` — cert-manager ClusterIssuer (DNS-01 via Cloudflare)
  - `certificate-wildcard.yaml` — wildcard cert `*.wind.etherport.net`
  - `tlsstore-default.yaml` — Traefik default TLSStore that serves the wildcard for every IngressRoute
  - `ingressroute-*.yaml` — IngressRoute resources for individual hosts

TLS is handled by cert-manager (DNS-01 via Cloudflare) + a default TLSStore
serving the `*.wind.etherport.net` wildcard; the old embedded-ACME workaround
files have been removed.

## Install / Upgrade

Both the controller and the IngressRoutes are Flux-managed:

```bash
kubectl annotate --overwrite -n flux-system helmrelease/traefik reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"   # picks up IngressRoute changes
```

## Verify

```bash
kubectl -n traefik get pods -o wide        # 2 replicas, Running
kubectl -n traefik logs deploy/traefik --tail=200
kubectl -n traefik get tlsstore default -o yaml
kubectl -n traefik get certificate wildcard-wind-etherport-net
```

## Dashboard

`traefik.wind.etherport.net` (IngressRoute defined in values / dashboard
helpers — uses the wildcard cert from TLSStore).
