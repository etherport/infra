"""
DNS Restrict IP Lambda

Updates a security group to allow DNS (port 53) access only from the current
public IP addresses of the homelab WAN connections.

Monitors three Route53 records:
- wind.etherport.net (main, updated by K8s CronJob)
- wan1.wind.etherport.net (WAN1, updated by router DDNS)
- wan2.wind.etherport.net (WAN2, updated by router DDNS)

The security group rules are kept in sync with these records:
- IPs in Route53 but not in SG -> rules are added
- IPs in SG but not in Route53 -> rules are removed
- Handles deduplication (same IP may appear in multiple records)
"""

import os
import logging
import boto3

# Initialize boto3 clients
route53 = boto3.client("route53")
ec2 = boto3.client("ec2")

# Logging setup
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Configuration from environment variables
HOSTED_ZONE_ID = os.environ["HOSTED_ZONE_ID"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
RECORD_NAMES = os.environ.get(
    "RECORD_NAMES",
    "wind.etherport.net,wan1.wind.etherport.net,wan2.wind.etherport.net"
).split(",")

# Port and protocols to manage
PORT = 53
PROTOCOLS = ["tcp", "udp"]


def get_route53_ips(hosted_zone_id: str, record_names: list[str]) -> set[str]:
    """
    Fetch A record IPs from Route53 for the given hostnames.
    Returns a set of unique IP addresses.
    """
    ips = set()

    for record_name in record_names:
        # Ensure record name ends with a dot for Route53 API
        fqdn = record_name if record_name.endswith(".") else f"{record_name}."

        try:
            response = route53.list_resource_record_sets(
                HostedZoneId=hosted_zone_id,
                StartRecordName=fqdn,
                StartRecordType="A",
                MaxItems="1"
            )

            record_sets = response.get("ResourceRecordSets", [])
            if record_sets and record_sets[0]["Name"] == fqdn and record_sets[0]["Type"] == "A":
                for rr in record_sets[0].get("ResourceRecords", []):
                    ip = rr.get("Value")
                    if ip:
                        ips.add(ip)
                        logger.info(f"Found IP {ip} for {record_name}")
            else:
                logger.warning(f"No A record found for {record_name}")

        except Exception as e:
            logger.error(f"Error fetching Route53 record for {record_name}: {e}")
            # Continue with other records rather than failing completely

    return ips


def get_security_group_ips(security_group_id: str) -> set[str]:
    """
    Get all IP addresses currently allowed on port 53 in the security group.
    Returns a set of IP addresses (without /32 suffix).
    """
    ips = set()

    try:
        response = ec2.describe_security_groups(GroupIds=[security_group_id])
        sg = response["SecurityGroups"][0]

        for permission in sg.get("IpPermissions", []):
            from_port = permission.get("FromPort")
            to_port = permission.get("ToPort")
            protocol = permission.get("IpProtocol")

            # Only look at port 53 rules
            if from_port == PORT and to_port == PORT and protocol in PROTOCOLS:
                for ip_range in permission.get("IpRanges", []):
                    cidr = ip_range.get("CidrIp", "")
                    if cidr.endswith("/32"):
                        ip = cidr[:-3]  # Remove /32 suffix
                        ips.add(ip)

    except Exception as e:
        logger.error(f"Error describing security group {security_group_id}: {e}")
        raise

    return ips


def add_security_group_rules(security_group_id: str, ips: set[str]) -> None:
    """Add port 53 ingress rules for the given IPs (both TCP and UDP)."""
    if not ips:
        return

    permissions = []
    for ip in ips:
        cidr = f"{ip}/32"
        for protocol in PROTOCOLS:
            permissions.append({
                "IpProtocol": protocol,
                "FromPort": PORT,
                "ToPort": PORT,
                "IpRanges": [{"CidrIp": cidr, "Description": "DNS access from homelab WAN"}]
            })

    try:
        ec2.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=permissions
        )
        logger.info(f"Added rules for IPs: {ips}")
    except ec2.exceptions.ClientError as e:
        if "InvalidPermission.Duplicate" in str(e):
            logger.info(f"Some rules already exist for {ips}")
        else:
            logger.error(f"Error adding rules: {e}")
            raise


def remove_security_group_rules(security_group_id: str, ips: set[str]) -> None:
    """Remove port 53 ingress rules for the given IPs (both TCP and UDP)."""
    if not ips:
        return

    permissions = []
    for ip in ips:
        cidr = f"{ip}/32"
        for protocol in PROTOCOLS:
            permissions.append({
                "IpProtocol": protocol,
                "FromPort": PORT,
                "ToPort": PORT,
                "IpRanges": [{"CidrIp": cidr}]
            })

    try:
        ec2.revoke_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=permissions
        )
        logger.info(f"Removed rules for IPs: {ips}")
    except ec2.exceptions.ClientError as e:
        if "InvalidPermission.NotFound" in str(e):
            logger.info(f"Some rules already removed for {ips}")
        else:
            logger.error(f"Error removing rules: {e}")
            raise


def lambda_handler(event, context):
    """
    Main handler: sync security group rules with Route53 DNS records.

    1. Get current IPs from Route53 (all monitored hostnames)
    2. Get current IPs from security group (port 53 rules)
    3. Add rules for IPs in Route53 but not in SG
    4. Remove rules for IPs in SG but not in Route53
    """
    logger.info(f"Starting DNS restrict IP sync for security group {SECURITY_GROUP_ID}")
    logger.info(f"Monitoring records: {RECORD_NAMES}")

    # Get expected IPs from Route53
    expected_ips = get_route53_ips(HOSTED_ZONE_ID, RECORD_NAMES)
    logger.info(f"Expected IPs from Route53: {expected_ips}")

    if not expected_ips:
        logger.error("No IPs found in Route53 - refusing to remove all rules")
        return {
            "statusCode": 500,
            "body": "No IPs found in Route53 records"
        }

    # Get current IPs from security group
    current_ips = get_security_group_ips(SECURITY_GROUP_ID)
    logger.info(f"Current IPs in security group: {current_ips}")

    # Calculate differences
    ips_to_add = expected_ips - current_ips
    ips_to_remove = current_ips - expected_ips

    # Apply changes
    if ips_to_add:
        logger.info(f"Adding IPs: {ips_to_add}")
        add_security_group_rules(SECURITY_GROUP_ID, ips_to_add)

    if ips_to_remove:
        logger.info(f"Removing IPs: {ips_to_remove}")
        remove_security_group_rules(SECURITY_GROUP_ID, ips_to_remove)

    if not ips_to_add and not ips_to_remove:
        logger.info("Security group already in sync with Route53")

    return {
        "statusCode": 200,
        "body": f"Security group {SECURITY_GROUP_ID} synced. Added: {ips_to_add or 'none'}, Removed: {ips_to_remove or 'none'}"
    }
