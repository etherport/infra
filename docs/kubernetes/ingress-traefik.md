# Traefik Ingress

## Purpose
- Ingress controller for cluster services
- TLS via ACME DNS-01 using Route53
- Can proxy non-k8s services too (as upstream URLs)

## Where files live
platform/kubernetes/traefik/
- traefik-values.yaml
- pvc-traefik-ceph.yaml
- traefik-acme-fix.yaml

## Install/Upgrade (Helm)
Example pattern:
helm repo add traefik https://traefik.github.io/charts
helm repo update

# PVC first (if using existingClaim)
kubectl apply -f platform/kubernetes/traefik/pvc-traefik-ceph.yaml

# install/upgrade
helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace \
  -f platform/kubernetes/traefik/traefik-values.yaml

## Verify
kubectl -n traefik get pods -o wide
kubectl -n traefik logs deploy/traefik --tail=200

## Dashboard
Uses IngressRoute in values.yaml:
traefik.wind.etherport.net
