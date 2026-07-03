# Technitium DNS Server Configuration

The canonical Technitium doc is **`platform/kubernetes/technitium/README.md`** —
it covers the K8s cluster, GitOps zones, and the Ansible-managed standalone
secondaries (dns-fallback `10.10.201.6`, and the consolidated AWS edge box
`vpn-aws` `10.10.100.10` — the former dedicated dns-aws instance was destroyed
2026-07, M110).
