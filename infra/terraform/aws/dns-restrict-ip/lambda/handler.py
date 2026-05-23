"""
DNS-Restrict-IP Lambda — multi-SG, multi-port ingress sync.

Keeps one or more (security_group, port, protocols) tuples in sync with
the current public IPs resolved from a set of Route53 A records.

For each rule spec:
  - IPs in Route53 but not in SG → ingress rule added
  - IPs in SG but not in Route53 → ingress rule removed
  - Same IP across multiple records is deduplicated

Originally written for the single dns_server SG (port 53 TCP+UDP). On
2026-05-23 extended to also manage the allow_ssh SG (port 22 TCP) so
that the same homelab WAN IPs that gate DNS access also gate SSH.

Env (one of these two is required):
  RULE_SPECS          JSON array of {security_group_id, port, protocols}.
                      Example:
                        [{"security_group_id":"sg-abc","port":53,"protocols":["tcp","udp"]},
                         {"security_group_id":"sg-def","port":22,"protocols":["tcp"]}]
  SECURITY_GROUP_ID   Single SG (legacy single-rule mode). Implies
                      {security_group_id: $val, port: 53, protocols: [tcp,udp]}
                      if RULE_SPECS isn't set.

Always required:
  HOSTED_ZONE_ID      Route53 hosted zone ID
  RECORD_NAMES        Comma-separated list of A record FQDNs
"""

import json
import logging
import os

import boto3

route53 = boto3.client("route53")
ec2 = boto3.client("ec2")

logger = logging.getLogger()
logger.setLevel(logging.INFO)

HOSTED_ZONE_ID = os.environ["HOSTED_ZONE_ID"]
RECORD_NAMES = os.environ.get(
    "RECORD_NAMES",
    "wind.etherport.net,wan1.wind.etherport.net,wan2.wind.etherport.net",
).split(",")


def _resolve_rule_specs():
    """Build the rule spec list from env vars, supporting both formats."""
    raw = os.environ.get("RULE_SPECS")
    if raw:
        return json.loads(raw)
    legacy_sg = os.environ.get("SECURITY_GROUP_ID")
    if legacy_sg:
        return [{
            "security_group_id": legacy_sg,
            "port": 53,
            "protocols": ["tcp", "udp"],
        }]
    raise RuntimeError("Neither RULE_SPECS nor SECURITY_GROUP_ID set")


def get_route53_ips(hosted_zone_id, record_names):
    """Return the union set of A record IPs across all names."""
    ips = set()
    for record_name in record_names:
        fqdn = record_name if record_name.endswith(".") else f"{record_name}."
        try:
            response = route53.list_resource_record_sets(
                HostedZoneId=hosted_zone_id,
                StartRecordName=fqdn,
                StartRecordType="A",
                MaxItems="1",
            )
            record_sets = response.get("ResourceRecordSets", [])
            if (
                record_sets
                and record_sets[0]["Name"] == fqdn
                and record_sets[0]["Type"] == "A"
            ):
                for rr in record_sets[0].get("ResourceRecords", []):
                    ip = rr.get("Value")
                    if ip:
                        ips.add(ip)
                        logger.info(f"Found IP {ip} for {record_name}")
            else:
                logger.warning(f"No A record found for {record_name}")
        except Exception as e:
            logger.error(f"Error fetching Route53 record for {record_name}: {e}")
    return ips


def get_security_group_ips(security_group_id, port, protocols):
    """Return the set of /32 IPs currently allowed for this (port, protocol-set)."""
    ips = set()
    try:
        response = ec2.describe_security_groups(GroupIds=[security_group_id])
        sg = response["SecurityGroups"][0]
        for permission in sg.get("IpPermissions", []):
            from_port = permission.get("FromPort")
            to_port = permission.get("ToPort")
            protocol = permission.get("IpProtocol")
            if from_port == port and to_port == port and protocol in protocols:
                for ip_range in permission.get("IpRanges", []):
                    cidr = ip_range.get("CidrIp", "")
                    if cidr.endswith("/32"):
                        ips.add(cidr[:-3])
    except Exception as e:
        logger.error(f"Error describing security group {security_group_id}: {e}")
        raise
    return ips


def _permissions(ips, port, protocols, description=None):
    """Build the IpPermissions list. Pass description for add (so the
    new rule is annotated with our marker) and omit it for revoke
    (AWS revoke matches CIDR+port+protocol but treats a passed
    Description as part of the match, so the rule won't be revoked
    if its live description differs from what we send — was silently
    leaving stale entries 2026-05-23)."""
    permissions = []
    for ip in ips:
        cidr = f"{ip}/32"
        for protocol in protocols:
            ip_range = {"CidrIp": cidr}
            if description is not None:
                ip_range["Description"] = description
            permissions.append({
                "IpProtocol": protocol,
                "FromPort": port,
                "ToPort": port,
                "IpRanges": [ip_range],
            })
    return permissions


def add_security_group_rules(security_group_id, ips, port, protocols, description):
    if not ips:
        return
    try:
        ec2.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=_permissions(ips, port, protocols, description),
        )
        logger.info(f"[{security_group_id}:{port}/{protocols}] added rules for {ips}")
    except ec2.exceptions.ClientError as e:
        if "InvalidPermission.Duplicate" in str(e):
            logger.info(f"[{security_group_id}:{port}/{protocols}] some rules already exist for {ips}")
        else:
            logger.error(f"[{security_group_id}:{port}/{protocols}] add error: {e}")
            raise


def remove_security_group_rules(security_group_id, ips, port, protocols):
    if not ips:
        return
    try:
        # Description omitted intentionally — see _permissions docstring.
        ec2.revoke_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=_permissions(ips, port, protocols),
        )
        logger.info(f"[{security_group_id}:{port}/{protocols}] removed rules for {ips}")
    except ec2.exceptions.ClientError as e:
        if "InvalidPermission.NotFound" in str(e):
            logger.info(f"[{security_group_id}:{port}/{protocols}] some rules already removed for {ips}")
        else:
            logger.error(f"[{security_group_id}:{port}/{protocols}] remove error: {e}")
            raise


def sync_rule(spec, expected_ips):
    """Reconcile one (SG, port, protocols) tuple against the expected IP set."""
    sg = spec["security_group_id"]
    port = int(spec["port"])
    protocols = list(spec["protocols"])
    description = spec.get("description", f"Managed by dns-restrict-ip ({port}/{','.join(protocols)})")

    current = get_security_group_ips(sg, port, protocols)
    add = expected_ips - current
    remove = current - expected_ips

    logger.info(f"[{sg}:{port}/{protocols}] current={current} expected={expected_ips}")

    if add:
        add_security_group_rules(sg, add, port, protocols, description)
    if remove:
        remove_security_group_rules(sg, remove, port, protocols)
    if not add and not remove:
        logger.info(f"[{sg}:{port}/{protocols}] in sync")

    return {"sg": sg, "port": port, "protocols": protocols, "added": list(add), "removed": list(remove)}


def lambda_handler(event, context):
    rule_specs = _resolve_rule_specs()
    logger.info(f"Starting DNS-restrict-IP sync for {len(rule_specs)} rule(s)")
    logger.info(f"Monitoring records: {RECORD_NAMES}")

    expected_ips = get_route53_ips(HOSTED_ZONE_ID, RECORD_NAMES)
    logger.info(f"Expected IPs from Route53: {expected_ips}")
    if not expected_ips:
        logger.error("No IPs found in Route53 — refusing to remove all rules")
        return {"statusCode": 500, "body": "No IPs found in Route53 records"}

    results = [sync_rule(spec, expected_ips) for spec in rule_specs]

    return {
        "statusCode": 200,
        "body": json.dumps({
            "expected_ips": list(expected_ips),
            "rules": results,
        }),
    }
