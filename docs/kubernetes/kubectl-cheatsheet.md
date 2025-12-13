# kubectl cheatsheet

## Cluster health
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -100

## Debugging a pod
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> --tail=200
kubectl -n <ns> logs <pod> -c <container> --tail=200
kubectl -n <ns> exec -it <pod> -- sh

## Resources
kubectl get svc -A
kubectl get ingress -A
kubectl get endpoints -A
kubectl get pv,pvc -A
kubectl get storageclass

## Rollouts
kubectl -n <ns> rollout status deploy/<name>
kubectl -n <ns> rollout restart deploy/<name>
kubectl -n <ns> rollout undo deploy/<name>

## Context / kubeconfig
echo $KUBECONFIG
kubectl config get-contexts
kubectl config use-context <name>
