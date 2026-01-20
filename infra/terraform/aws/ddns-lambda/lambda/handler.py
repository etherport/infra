"""
DDNS Lambda Handler for Ubiquiti Router

Provides a DynDNS-compatible endpoint for updating Route53 DNS records.
Used by Ubiquiti router to update wan1/wan2.wind.etherport.net records.

Responses follow DynDNS protocol:
- good <ip>   : Updated successfully
- nochg <ip>  : No change needed
- badauth     : Authentication failed
- nohost      : Invalid hostname
- 911         : Server error
"""

import base64
import json
import os
import re
import boto3
from functools import lru_cache


# Environment variables (set by Terraform)
HOSTED_ZONE_ID = os.environ.get("HOSTED_ZONE_ID")
ALLOWED_HOSTNAMES = os.environ.get("ALLOWED_HOSTNAMES", "").split(",")
SECRET_ARN = os.environ.get("SECRET_ARN")
TTL = int(os.environ.get("TTL", "300"))

# AWS clients
route53 = boto3.client("route53")
secrets_manager = boto3.client("secretsmanager")

# IPv4 regex pattern
IPV4_PATTERN = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")


@lru_cache(maxsize=1)
def get_api_key():
    """Retrieve API key from Secrets Manager (cached for Lambda warm starts)."""
    response = secrets_manager.get_secret_value(SecretId=SECRET_ARN)
    secret = json.loads(response["SecretString"])
    return secret["api_key"]


def validate_ip(ip):
    """Validate IPv4 address format and range."""
    if not ip or not IPV4_PATTERN.match(ip):
        return False
    octets = ip.split(".")
    return all(0 <= int(octet) <= 255 for octet in octets)


def get_current_ip(hostname):
    """Get current IP address for hostname from Route53."""
    try:
        response = route53.list_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            StartRecordName=hostname,
            StartRecordType="A",
            MaxItems="1",
        )
        print(f"Route53 list response for {hostname}: {response.get('ResourceRecordSets', [])}")
        for record in response.get("ResourceRecordSets", []):
            if record["Name"].rstrip(".") == hostname and record["Type"] == "A":
                if record.get("ResourceRecords"):
                    return record["ResourceRecords"][0]["Value"]
        return None
    except Exception as e:
        print(f"Error getting current IP for {hostname}: {e}")
        return None


def update_dns(hostname, ip):
    """Update Route53 A record for hostname."""
    response = route53.change_resource_record_sets(
        HostedZoneId=HOSTED_ZONE_ID,
        ChangeBatch={
            "Comment": f"DDNS update from Lambda for {hostname}",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": hostname,
                        "Type": "A",
                        "TTL": TTL,
                        "ResourceRecords": [{"Value": ip}],
                    },
                }
            ],
        },
    )
    change_info = response.get("ChangeInfo", {})
    print(f"Route53 change response: Id={change_info.get('Id')}, Status={change_info.get('Status')}")


def lambda_handler(event, context):
    """
    Handle DDNS update request.

    Expected request format:
    GET /update?hostname=<hostname>&myip=<ip>
    Header: x-api-key: <api-key>

    The myip parameter is optional - if not provided, uses source IP.
    """
    try:
        # Extract request details
        headers = event.get("headers", {})
        query_params = event.get("queryStringParameters", {}) or {}
        request_context = event.get("requestContext", {})

        # Get API key from header (case-insensitive)
        # Supports both x-api-key header and HTTP Basic Auth (for DynDNS clients)
        api_key = None
        for key, value in headers.items():
            if key.lower() == "x-api-key":
                api_key = value
                break
            elif key.lower() == "authorization" and value.lower().startswith("basic "):
                # Extract password from Basic Auth (base64 encoded "username:password")
                try:
                    encoded = value[6:]  # Remove "Basic " prefix
                    decoded = base64.b64decode(encoded).decode("utf-8")
                    # Password is the API key (username is ignored)
                    if ":" in decoded:
                        api_key = decoded.split(":", 1)[1]
                except Exception:
                    pass

        # Authenticate
        if not api_key or api_key != get_api_key():
            print(f"Authentication failed - invalid API key")
            return {"statusCode": 200, "body": "badauth"}

        # Get hostname
        hostname = query_params.get("hostname", "").lower().strip()
        if not hostname:
            print("No hostname provided")
            return {"statusCode": 200, "body": "nohost"}

        # Validate hostname is in allowed list
        if hostname not in [h.lower() for h in ALLOWED_HOSTNAMES]:
            print(f"Hostname not allowed: {hostname}")
            return {"statusCode": 200, "body": "nohost"}

        # Get IP - from parameter or source IP
        ip = query_params.get("myip", "").strip()
        if not ip:
            # Try to get source IP from API Gateway
            http_context = request_context.get("http", {})
            ip = http_context.get("sourceIp", "")

        if not ip:
            print("Could not determine IP address")
            return {"statusCode": 200, "body": "911"}

        # Validate IP format
        if not validate_ip(ip):
            print(f"Invalid IP format: {ip}")
            return {"statusCode": 200, "body": "911"}

        # Check current DNS value
        current_ip = get_current_ip(hostname)
        print(f"Current IP for {hostname}: {current_ip}, requested IP: {ip}")

        if current_ip == ip:
            # No change needed
            return {"statusCode": 200, "body": f"nochg {ip}"}

        # Update DNS
        update_dns(hostname, ip)
        print(f"Updated {hostname} from {current_ip} to {ip}")

        return {"statusCode": 200, "body": f"good {ip}"}

    except Exception as e:
        print(f"Error processing DDNS request: {str(e)}")
        return {"statusCode": 200, "body": "911"}
