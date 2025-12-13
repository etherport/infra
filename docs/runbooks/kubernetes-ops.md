# Kubernetes Ops Runbook

## Reboot / Shutdown sequence (practical)
If you must power down the Proxmox host:
1) (Optional) cordon nodes so workloads don’t churn:
   kubectl cordon k8s-w1 k8s-w2
2) Shut down worker VMs first (k8s-w1, k8s-w2)
3) Shut down control plane VM (k8s-cp1)
4) Power down Proxmox host

Startup:
1) Start Proxmox host
2) Start control plane VM first, wait for API:
   kubectl get nodes (from your Mac) OR ssh into cp and check kubelet
3) Start workers
4) Uncordon:
   kubectl uncordon k8s-w1 k8s-w2

## Basic cluster checks
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -100

## Troubleshooting patterns
- Pending pods: check PVC / StorageClass / node resources
- CrashLoopBackOff: check logs + config/secret mounts
