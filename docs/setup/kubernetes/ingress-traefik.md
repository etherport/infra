# Traefik Ingress

## Purpose
- Ingress controller for cluster services (HelmRelease, HA `replicas: 2`)
- TLS via cert-manager wildcard `*.wind.etherport.net` + Traefik default
  `TLSStore` (no embedded ACME, no Route53 cert resolver on Traefik
  itself any more)
- Can proxy non-k8s services too (UPS/PDU/Proxmox web UIs)

## Where files live

- `clusters/wind/helm-releases/traefik.yaml` — the Flux HelmRelease
- `platform/kubernetes/traefik/`
  - `traefik-values.yaml` — Helm values (no PVC, no ACME)
  - `clusterissuer-letsencrypt.yaml` — cert-manager ClusterIssuer (DNS-01 via Route53)
  - `certificate-wildcard.yaml` — wildcard cert `*.wind.etherport.net`
  - `tlsstore-default.yaml` — Traefik default TLSStore that serves the wildcard for every IngressRoute
  - `route53-credentials.sops.yaml` — SOPS-encrypted AWS creds for cert-manager DNS-01
  - `ingressroute-*.yaml` — IngressRoute resources for individual hosts

TLS is handled by cert-manager (DNS-01) + a default TLSStore serving the
`*.wind.etherport.net` wildcard; the old embedded-ACME workaround files have
been removed.

## Install / Upgrade

Both the controller and the IngressRoutes are Flux-managed:

```bash
flux reconcile helmrelease traefik -n flux-system
flux reconcile kustomization flux-system   # picks up IngressRoute changes
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
