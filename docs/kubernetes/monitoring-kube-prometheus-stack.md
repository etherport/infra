# Monitoring (kube-prometheus-stack)

## Where files live
platform/kubernetes/monitoring/kube-prometheus-stack-values.yaml

## Install/Upgrade (Helm)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f platform/kubernetes/monitoring/kube-prometheus-stack-values.yaml

## Verify
kubectl -n monitoring get pods -o wide
kubectl -n monitoring get svc -o wide
