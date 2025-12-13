# MetalLB

## Purpose
Provides LoadBalancer IPs in a bare-metal cluster (no cloud LB).

## Where files live
platform/kubernetes/metallb/metallb-wind.yaml

## Apply
kubectl apply -f platform/kubernetes/metallb/metallb-wind.yaml

## Verify
kubectl get pods -n metallb-system -o wide
kubectl get svc -A | grep LoadBalancer
