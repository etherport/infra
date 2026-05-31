# AWS Private DNS — `aws.etherport.net`

> **HISTORICAL — DELETED 2026-05-27.** The Route53 private hosted zone
> `aws.etherport.net` was deleted as part of the etherport.net →
> Cloudflare migration. It never had any real content (no RDS, no
> private LBs, etc. ever landed on it). The Technitium conditional
> forwarder + the Resolver Inbound Endpoint at `52.40.219.113` are
> dormant — the forwarder returns SERVFAIL for `*.aws.etherport.net`
> queries because the zone no longer exists.
>
> If a future need for VPC-internal DNS arises, the cleanest revival
> path is a new Route53 private zone (the `terraform-dns` IAM policy
> already has the perms — see H19 in `docs/planning/outstanding-work.md`)
> + restore the Technitium forwarder pair below. The doc is kept as a
> reference for that scenario.

## Background

AWS-native resources (RDS, private LBs, EC2 alias hostnames, etc.) live
under `aws.etherport.net` — a Route53 **private** hosted zone associated
with the `private-infra-vpc`. This separates them from the homelab's
`wind.etherport.net` zone without inventing a new TLD and follows the
convention "no `wind` prefix for AWS-native resources."

Records in `aws.etherport.net`:
- Resolvable from **within AWS** via Route53 Resolver (VPC DNS).
- Resolvable from **on-prem** via the Route53 Resolver Inbound Endpoint
  at `52.40.219.113` (reachable across the homelab → AWS VPN tunnel).
- **Not** resolvable from the public internet — by design.

Auto-generated AWS DNS like `ip-10-10-100-50.us-west-2.compute.internal`
is also served by the Resolver Inbound Endpoint.

## Technitium forwarder setup (one-time)

After `terraform apply` for the `route53` module creates the zone, add
two conditional forwarders to Technitium so on-prem queries flow to the
AWS resolver:

1. Open Technitium UI: `https://10.10.201.5:5380/` (or via Tailscale).
2. Go to **Settings → DNS Settings → Forwarders → Add Forwarder Group**
   (or use the existing main forwarder group).
3. Add two new conditional forwarder entries:

| Domain                    | Forwarder       | Protocol |
|---------------------------|-----------------|----------|
| `aws.etherport.net`       | `52.40.219.113` | UDP      |
| `us-west-2.compute.internal` | `52.40.219.113` | UDP      |

   The second entry covers AWS auto-generated reverse DNS for EC2
   instances. If you ever add another region, add a matching forwarder
   (e.g. `us-east-1.compute.internal`).

4. Repeat on `technitium-1` (10.10.201.6) — Technitium config is per-
   instance for now. (The `dns-sync-watcher` pod syncs DNS records but
   not forwarder rules — see `platform/kubernetes/technitium/`.)

## Verification

```bash
# From a K8s node:
dig @10.10.201.5 some-instance.aws.etherport.net      # should resolve
dig @10.10.201.5 ip-10-10-100-50.us-west-2.compute.internal  # should resolve

# From a pod (via cluster DNS):
kubectl run -i --rm --restart=Never dns-test --image=alpine:3 -- sh -c \
  "apk add --no-cache bind-tools >/dev/null && dig some-instance.aws.etherport.net"
```

## Once verified working

Drop the AWS resolver IP from the K8s VM netplan so we go back under
the 3-nameserver K8s pod limit:

1. In `infra/packer/ubuntu-cloud-init/scripts/setup-cloud-base.sh`,
   the default `NAMESERVERS` is already `10.10.201.5 10.10.201.6`
   (no AWS IP). Confirm.
2. For existing live nodes that have `52.40.219.113` in their
   `50-cloud-init.yaml`, run the ansible playbook to overwrite:
   ```bash
   cd infra/ansible
   ansible-playbook -i ../kubespray/inventory/inventory.ini \
     playbooks/k8s-node-fixes.yml --limit k8s_cluster \
     --private-key /tmp/auto-key -u ubuntu --become
   ```
   (Once the playbook gains a netplan-overwrite task — see TODO below.)

## Adding records to `aws.etherport.net`

Records aren't auto-managed (yet) — add them via TF in
`infra/terraform/aws/route53/`:

```hcl
resource "aws_route53_record" "example_rds" {
  zone_id = aws_route53_zone.aws_etherport.zone_id
  name    = "primary-db.aws.etherport.net"
  type    = "CNAME"
  ttl     = 300
  records = ["primary-db.cluster-xxx.us-west-2.rds.amazonaws.com"]
}
```

External-DNS could be wired up later to auto-manage CNAMEs from K8s
Ingress / Service annotations.
