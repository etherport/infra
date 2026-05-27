"""
DDNS Lambda Handler for Ubiquiti Router

Provides a DynDNS-compatible endpoint for updating Cloudflare DNS records.
Used by the Ubiquiti router to keep wan1/wan2.wind.etherport.net pointed
at the current public IPs of each WAN.

Responses follow DynDNS protocol:
- good <ip>   : Updated successfully
- nochg <ip>  : No change needed
- badauth     : Authentication failed
- nohost      : Invalid hostname
- 911         : Server error

History: originally wrote to AWS Route53. Migrated 2026-05-27 to write
to Cloudflare after the etherport.net Route53 zone was deleted as part
of the broader DNS-to-CF migration.

Secrets Manager secret (SECRET_ARN) is now expected to hold BOTH:
  {"api_key": "<router-side-shared-secret>",
   "cf_api_token": "<CF API token, Zone:DNS:Edit on the target zone>"}

If only `api_key` is present (legacy), the Lambda returns 911 to make
the misconfig obvious instead of silently degrading.
"""

import base64
import json
import os
import re
import urllib.error
import urllib.request
from functools import lru_cache

import boto3


# Environment variables (set by Terraform)
CF_ZONE_ID = os.environ.get("CF_ZONE_ID")
ALLOWED_HOSTNAMES = os.environ.get("ALLOWED_HOSTNAMES", "").split(",")
SECRET_ARN = os.environ.get("SECRET_ARN")
TTL = int(os.environ.get("TTL", "300"))

# AWS clients (only Secrets Manager — DNS writes go to CF via HTTPS).
secrets_manager = boto3.client("secretsmanager")

# IPv4 regex pattern
IPV4_PATTERN = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")

_CF_API = "https://api.cloudflare.com/client/v4"


@lru_cache(maxsize=1)
def _load_secret():
    """Retrieve secret payload from Secrets Manager (cached per warm start)."""
    resp = secrets_manager.get_secret_value(SecretId=SECRET_ARN)
    return json.loads(resp["SecretString"])


def get_api_key():
    return _load_secret()["api_key"]


def get_cf_token():
    payload = _load_secret()
    token = payload.get("cf_api_token", "")
    if not token:
        raise RuntimeError(
            "Secrets Manager payload is missing `cf_api_token`. "
            "Update the secret to include both api_key and cf_api_token."
        )
    return token


def validate_ip(ip):
    if not ip or not IPV4_PATTERN.match(ip):
        return False
    octets = ip.split(".")
    return all(0 <= int(octet) <= 255 for octet in octets)


def _cf_request(method, path, body=None):
    req = urllib.request.Request(
        url=f"{_CF_API}{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {get_cf_token()}",
            "Content-Type": "application/json",
        },
        data=json.dumps(body).encode() if body is not None else None,
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _lookup_record(hostname):
    """Return (record_id, current_ip) or (None, None) if no A record."""
    data = _cf_request("GET", f"/zones/{CF_ZONE_ID}/dns_records?type=A&name={hostname}")
    results = data.get("result", []) if data.get("success") else []
    if results:
        return results[0]["id"], results[0]["content"]
    return None, None


def get_current_ip(hostname):
    try:
        _, ip = _lookup_record(hostname)
        return ip
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError) as e:
        print(f"Error looking up {hostname} in CF: {e}")
        return None


def update_dns(hostname, ip):
    """UPSERT A record on the CF zone. Creates if missing, otherwise PUTs."""
    record_id, _ = _lookup_record(hostname)
    body = {
        "type": "A",
        "name": hostname,
        "content": ip,
        "ttl": TTL,
        "proxied": False,
        "comment": "Managed by ddns-updater Lambda",
    }
    if record_id:
        resp = _cf_request("PUT", f"/zones/{CF_ZONE_ID}/dns_records/{record_id}", body)
    else:
        resp = _cf_request("POST", f"/zones/{CF_ZONE_ID}/dns_records", body)
    if not resp.get("success"):
        raise RuntimeError(f"CF update failed: {resp.get('errors')}")
    print(f"CF update OK: {hostname} -> {ip} (record_id={resp['result']['id']})")


def lambda_handler(event, context):
    """
    Handle DDNS update request.

    Expected request format:
      GET /update?hostname=<hostname>&myip=<ip>
      Header: x-api-key: <api-key>     (or HTTP Basic with key in password slot)

    The myip parameter is optional - if not provided, uses source IP.
    """
    try:
        headers = event.get("headers", {})
        query_params = event.get("queryStringParameters", {}) or {}
        request_context = event.get("requestContext", {})

        # Header-based auth (x-api-key OR Basic Auth password slot)
        api_key = None
        for key, value in headers.items():
            if key.lower() == "x-api-key":
                api_key = value
                break
            elif key.lower() == "authorization" and value.lower().startswith("basic "):
                try:
                    encoded = value[6:]
                    decoded = base64.b64decode(encoded).decode("utf-8")
                    if ":" in decoded:
                        api_key = decoded.split(":", 1)[1]
                except Exception:
                    pass

        if not api_key or api_key != get_api_key():
            print("Authentication failed - invalid API key")
            return {"statusCode": 200, "body": "badauth"}

        hostname = query_params.get("hostname", "").lower().strip()
        if not hostname:
            return {"statusCode": 200, "body": "nohost"}

        if hostname not in [h.lower() for h in ALLOWED_HOSTNAMES]:
            print(f"Hostname not allowed: {hostname}")
            return {"statusCode": 200, "body": "nohost"}

        ip = query_params.get("myip", "").strip()
        if not ip:
            ip = request_context.get("http", {}).get("sourceIp", "")
        if not ip:
            print("Could not determine IP address")
            return {"statusCode": 200, "body": "911"}

        if not validate_ip(ip):
            print(f"Invalid IP format: {ip}")
            return {"statusCode": 200, "body": "911"}

        current_ip = get_current_ip(hostname)
        print(f"Current IP for {hostname}: {current_ip}, requested IP: {ip}")

        if current_ip == ip:
            return {"statusCode": 200, "body": f"nochg {ip}"}

        update_dns(hostname, ip)
        print(f"Updated {hostname} from {current_ip} to {ip}")
        return {"statusCode": 200, "body": f"good {ip}"}

    except Exception as e:
        print(f"Error processing DDNS request: {str(e)}")
        return {"statusCode": 200, "body": "911"}
