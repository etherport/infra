# Kopia (Kubernetes)

Deploys Kopia Server in-cluster with:
- Persistent Kopia repository on Ceph PVC
- Persistent Kopia config/cache on Ceph PVC
- Traefik IngressRoute at `https://kopia.wind.etherport.net` (TLS via Route53 DNS-01)

## Files
- `00-namespace.yaml` — namespace `backups`
- `01-pvc-repo.yaml` — PVC for Kopia repository (`/repo`)
- `02-pvc-config.yaml` — PVC for Kopia config/cache
- `03-secret-template.yaml` — template only (do not apply with real values)
- `04-configmap-entrypoint.yaml` — idempotent repo init/connect + server start
- `05-deployment.yaml` — Kopia server deployment
- `06-service.yaml` — ClusterIP service
- `07-ingressroute.yaml` — Traefik IngressRoute (`websecure`, `route53` resolver)

## Prereqs
1) Traefik installed and working with `certResolver: route53`
2) DNS `kopia.wind.etherport.net` points to your Traefik LB IP (MetalLB VIP)
3) Default StorageClass is Ceph (or set `storageClassName` explicitly in PVCs)

Check storage classes:
```bash
kubectl get storageclass

Create the runtime secret (recommended) instead of committing real creds:

kubectl -n backups create secret generic kopia-credentials \
  --from-literal=KOPIA_PASSWORD='YOUR_REPO_PASSWORD' \
  --from-literal=KOPIA_SERVER_USER='admin' \
  --from-literal=KOPIA_SERVER_PASS='YOUR_UI_PASSWORD'

Install / Deploy
From repo root:

kubectl apply -f platform/kubernetes/apps/kopia/00-namespace.yaml
kubectl apply -f platform/kubernetes/apps/kopia/01-pvc-repo.yaml
kubectl apply -f platform/kubernetes/apps/kopia/02-pvc-config.yaml
kubectl apply -f platform/kubernetes/apps/kopia/04-configmap-entrypoint.yaml
kubectl apply -f platform/kubernetes/apps/kopia/05-deployment.yaml
kubectl apply -f platform/kubernetes/apps/kopia/06-service.yaml
kubectl apply -f platform/kubernetes/apps/kopia/07-ingressroute.yaml

Verify:

kubectl -n backups get pvc
kubectl -n backups get pods -o wide
kubectl -n backups logs deploy/kopia --tail=200

Open:
	•	https://kopia.wind.etherport.net
Login with KOPIA_SERVER_USER / KOPIA_SERVER_PASS

Upgrade

Kopia image tag is currently kopia/kopia:latest. You may want to pin to a version.

kubectl -n backups rollout restart deploy/kopia
kubectl -n backups rollout status deploy/kopia