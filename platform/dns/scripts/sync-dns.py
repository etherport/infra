#!/usr/bin/env python3
"""
Technitium DNS GitOps Sync Script

Syncs DNS zone records from YAML files to Technitium DNS Server via its HTTP API.
Designed to be run from GitHub Actions or locally for testing.

Usage:
    python sync-dns.py --zone wind.etherport.net --dry-run
    python sync-dns.py --zone wind.etherport.net --apply

Environment Variables:
    TECHNITIUM_URL: Base URL of Technitium DNS server (e.g., http://10.10.201.72:5380)
    TECHNITIUM_USER: API username
    TECHNITIUM_PASS: API password
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

import yaml


class TechnitiumClient:
    """Client for Technitium DNS Server API."""

    def __init__(self, base_url: str, username: str, password: str):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.token: str | None = None

    def _request(self, endpoint: str, params: dict[str, Any] | None = None) -> dict:
        """Make an API request to Technitium."""
        if params is None:
            params = {}

        if self.token:
            params["token"] = self.token

        url = f"{self.base_url}/api/{endpoint}"
        if params:
            url = f"{url}?{urlencode(params)}"

        try:
            req = Request(url)
            with urlopen(req, timeout=30) as response:
                data = json.loads(response.read().decode("utf-8"))
                if data.get("status") != "ok":
                    raise Exception(f"API error: {data.get('errorMessage', 'Unknown error')}")
                return data
        except HTTPError as e:
            raise Exception(f"HTTP error {e.code}: {e.reason}")
        except URLError as e:
            raise Exception(f"URL error: {e.reason}")

    def login(self) -> None:
        """Authenticate and get API token."""
        data = self._request("user/login", {
            "user": self.username,
            "pass": self.password
        })
        self.token = data.get("token")
        if not self.token:
            raise Exception("Failed to get authentication token")
        print(f"✓ Authenticated to {self.base_url}")

    def get_zone_records(self, zone: str) -> list[dict]:
        """Get all records for a zone."""
        data = self._request("zones/records/get", {
            "domain": zone,
            "zone": zone,
            "listZone": "true"
        })
        return data.get("response", {}).get("records", [])

    def add_record(self, zone: str, name: str, record_type: str, value: str,
                   ttl: int = 3600, comment: str = "") -> None:
        """Add a DNS record."""
        # Build full domain name
        domain = name if name == zone or name.endswith(f".{zone}") else f"{name}.{zone}"

        params = {
            "zone": zone,
            "domain": domain,
            "type": record_type,
            "ttl": ttl,
            "overwrite": "true",  # Update if exists
            "comments": comment
        }

        # Set type-specific parameters
        if record_type == "A":
            params["ipAddress"] = value
        elif record_type == "AAAA":
            params["ipAddress"] = value
        elif record_type == "CNAME":
            params["cname"] = value
        elif record_type == "MX":
            parts = value.split()
            params["preference"] = parts[0] if len(parts) > 1 else "10"
            params["exchange"] = parts[-1]
        elif record_type == "TXT":
            params["text"] = value
        elif record_type == "SRV":
            parts = value.split()
            if len(parts) >= 4:
                params["priority"] = parts[0]
                params["weight"] = parts[1]
                params["port"] = parts[2]
                params["target"] = parts[3]
        elif record_type == "CAA":
            parts = value.split(None, 2)
            if len(parts) >= 3:
                params["flags"] = parts[0]
                params["tag"] = parts[1]
                params["value"] = parts[2].strip('"')
        else:
            raise ValueError(f"Unsupported record type: {record_type}")

        self._request("zones/records/add", params)

    def delete_record(self, zone: str, name: str, record_type: str, value: str) -> None:
        """Delete a DNS record."""
        domain = name if name == zone or name.endswith(f".{zone}") else f"{name}.{zone}"

        params = {
            "zone": zone,
            "domain": domain,
            "type": record_type,
        }

        # Set type-specific parameters for deletion
        if record_type in ("A", "AAAA"):
            params["ipAddress"] = value
        elif record_type == "CNAME":
            params["cname"] = value
        elif record_type == "MX":
            parts = value.split()
            params["exchange"] = parts[-1]
        elif record_type == "TXT":
            params["text"] = value

        self._request("zones/records/delete", params)


def load_zone_file(zone_file: Path) -> dict:
    """Load and parse a zone YAML file."""
    with open(zone_file) as f:
        return yaml.safe_load(f)


def normalize_record(record: dict, zone: str, default_ttl: int) -> dict:
    """Normalize a record from YAML format."""
    name = record.get("name", "@")
    if name == "@":
        name = zone
    elif not name.endswith(f".{zone}"):
        name = f"{name}.{zone}"

    return {
        "name": name,
        "type": record.get("type", "A"),
        "value": record.get("value", ""),
        "ttl": record.get("ttl", default_ttl),
        "comment": record.get("comment", "")
    }


def get_record_value(api_record: dict) -> str:
    """Extract the value from an API record based on its type."""
    rdata = api_record.get("rData", {})
    record_type = api_record.get("type", "")

    if record_type in ("A", "AAAA"):
        return rdata.get("ipAddress", "")
    elif record_type == "CNAME":
        return rdata.get("cname", "")
    elif record_type == "MX":
        return f"{rdata.get('preference', '')} {rdata.get('exchange', '')}"
    elif record_type == "TXT":
        return rdata.get("text", "")
    elif record_type == "NS":
        return rdata.get("nameServer", "")
    elif record_type == "SRV":
        return f"{rdata.get('priority', '')} {rdata.get('weight', '')} {rdata.get('port', '')} {rdata.get('target', '')}"
    elif record_type == "CAA":
        return f"{rdata.get('flags', '')} {rdata.get('tag', '')} \"{rdata.get('value', '')}\""
    return ""


def compute_diff(desired: list[dict], current: list[dict], zone: str) -> tuple[list, list, list]:
    """
    Compute the difference between desired and current records.

    Returns: (to_add, to_update, to_delete)
    """
    # Build lookup of current records (excluding SOA, NS which are auto-managed)
    current_map: dict[tuple, dict] = {}
    for rec in current:
        if rec.get("type") in ("SOA", "NS"):
            continue
        key = (rec.get("name", ""), rec.get("type", ""))
        current_map[key] = rec

    # Build lookup of desired records
    desired_map: dict[tuple, dict] = {}
    for rec in desired:
        key = (rec["name"], rec["type"])
        desired_map[key] = rec

    to_add = []
    to_update = []
    to_delete = []

    # Find records to add or update
    for key, desired_rec in desired_map.items():
        if key not in current_map:
            to_add.append(desired_rec)
        else:
            current_rec = current_map[key]
            current_value = get_record_value(current_rec)
            if current_value != desired_rec["value"]:
                to_update.append(desired_rec)
            elif current_rec.get("ttl") != desired_rec["ttl"]:
                to_update.append(desired_rec)

    # Find records to delete (in current but not in desired)
    for key, current_rec in current_map.items():
        if key not in desired_map:
            to_delete.append({
                "name": current_rec.get("name", ""),
                "type": current_rec.get("type", ""),
                "value": get_record_value(current_rec),
                "ttl": current_rec.get("ttl", 3600)
            })

    return to_add, to_update, to_delete


def main():
    parser = argparse.ArgumentParser(description="Sync DNS records to Technitium")
    parser.add_argument("--zone", required=True, help="Zone name to sync")
    parser.add_argument("--dry-run", action="store_true", help="Show changes without applying")
    parser.add_argument("--apply", action="store_true", help="Apply changes to Technitium")
    parser.add_argument("--zones-dir", default="zones", help="Directory containing zone YAML files")
    parser.add_argument("--delete-unmanaged", action="store_true",
                        help="Delete records not in YAML (use with caution)")
    args = parser.parse_args()

    if not args.dry_run and not args.apply:
        print("Error: Must specify either --dry-run or --apply")
        sys.exit(1)

    # Get configuration from environment
    base_url = os.environ.get("TECHNITIUM_URL")
    username = os.environ.get("TECHNITIUM_USER")
    password = os.environ.get("TECHNITIUM_PASS")

    if not all([base_url, username, password]):
        print("Error: Missing environment variables. Required:")
        print("  TECHNITIUM_URL, TECHNITIUM_USER, TECHNITIUM_PASS")
        sys.exit(1)

    # Find zone file
    script_dir = Path(__file__).parent.parent
    zones_dir = script_dir / args.zones_dir
    zone_file = zones_dir / f"{args.zone}.yaml"

    if not zone_file.exists():
        print(f"Error: Zone file not found: {zone_file}")
        sys.exit(1)

    # Load desired state from YAML
    print(f"Loading zone file: {zone_file}")
    zone_data = load_zone_file(zone_file)
    zone_name = zone_data.get("zone", args.zone)
    default_ttl = zone_data.get("ttl", 3600)

    desired_records = [
        normalize_record(rec, zone_name, default_ttl)
        for rec in zone_data.get("records", [])
    ]
    print(f"Found {len(desired_records)} records in YAML")

    # Connect to Technitium
    client = TechnitiumClient(base_url, username, password)
    client.login()

    # Get current state from API
    print(f"Fetching current records for zone: {zone_name}")
    current_records = client.get_zone_records(zone_name)
    managed_count = sum(1 for r in current_records if r.get("type") not in ("SOA", "NS"))
    print(f"Found {managed_count} managed records in Technitium (excluding SOA/NS)")

    # Compute diff
    to_add, to_update, to_delete = compute_diff(desired_records, current_records, zone_name)

    # Print summary
    print("\n" + "=" * 60)
    print("SYNC SUMMARY")
    print("=" * 60)

    if to_add:
        print(f"\n📥 Records to ADD ({len(to_add)}):")
        for rec in to_add:
            print(f"  + {rec['name']} {rec['type']} {rec['value']}")

    if to_update:
        print(f"\n📝 Records to UPDATE ({len(to_update)}):")
        for rec in to_update:
            print(f"  ~ {rec['name']} {rec['type']} -> {rec['value']}")

    if to_delete and args.delete_unmanaged:
        print(f"\n🗑️  Records to DELETE ({len(to_delete)}):")
        for rec in to_delete:
            print(f"  - {rec['name']} {rec['type']} {rec['value']}")
    elif to_delete:
        print(f"\n⚠️  Unmanaged records ({len(to_delete)}) - use --delete-unmanaged to remove:")
        for rec in to_delete:
            print(f"  ? {rec['name']} {rec['type']} {rec['value']}")

    if not to_add and not to_update and (not to_delete or not args.delete_unmanaged):
        print("\n✅ Zone is in sync - no changes needed")
        return

    # Apply changes if requested
    if args.apply:
        print("\n" + "=" * 60)
        print("APPLYING CHANGES")
        print("=" * 60)

        errors = []

        for rec in to_add:
            try:
                client.add_record(zone_name, rec["name"], rec["type"], rec["value"],
                                  rec["ttl"], rec.get("comment", ""))
                print(f"  ✓ Added: {rec['name']} {rec['type']}")
            except Exception as e:
                print(f"  ✗ Failed to add {rec['name']}: {e}")
                errors.append(str(e))

        for rec in to_update:
            try:
                client.add_record(zone_name, rec["name"], rec["type"], rec["value"],
                                  rec["ttl"], rec.get("comment", ""))
                print(f"  ✓ Updated: {rec['name']} {rec['type']}")
            except Exception as e:
                print(f"  ✗ Failed to update {rec['name']}: {e}")
                errors.append(str(e))

        if args.delete_unmanaged:
            for rec in to_delete:
                try:
                    client.delete_record(zone_name, rec["name"], rec["type"], rec["value"])
                    print(f"  ✓ Deleted: {rec['name']} {rec['type']}")
                except Exception as e:
                    print(f"  ✗ Failed to delete {rec['name']}: {e}")
                    errors.append(str(e))

        if errors:
            print(f"\n❌ Completed with {len(errors)} error(s)")
            sys.exit(1)
        else:
            print("\n✅ All changes applied successfully")
    else:
        print("\n🔍 Dry run - no changes applied. Use --apply to make changes.")


if __name__ == "__main__":
    main()
