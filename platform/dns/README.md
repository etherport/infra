# DNS GitOps

This directory contains the GitOps configuration for managing DNS records via Technitium DNS Server.

## Overview

DNS records are defined as YAML files in the `zones/` directory. Changes pushed to the `main` branch are automatically synced to Technitium via GitHub Actions.

## Directory Structure

```
platform/dns/
├── README.md           # This file
├── zones/              # Zone definition files
│   └── wind.etherport.net.yaml
└── scripts/
    └── sync-dns.py     # Sync script for Technitium API
```

## Zone File Format

Each zone is defined in a YAML file named `{zone}.yaml`:

```yaml
zone: wind.etherport.net
ttl: 3600  # Default TTL in seconds

records:
  - name: www           # Record name (@ for apex)
    type: A             # Record type (A, AAAA, CNAME, MX, TXT, SRV, CAA)
    value: 10.10.201.70
    ttl: 300            # Optional, overrides zone default
    comment: Web server # Optional comment

  - name: mail
    type: MX
    value: 10 mail.example.com.  # MX format: priority hostname

  - name: "@"
    type: TXT
    value: "v=spf1 include:_spf.google.com ~all"
```

## Supported Record Types

| Type  | Value Format | Example |
|-------|--------------|---------|
| A     | IPv4 address | `10.10.201.70` |
| AAAA  | IPv6 address | `2001:db8::1` |
| CNAME | Hostname | `www.example.com.` |
| MX    | `priority hostname` | `10 mail.example.com.` |
| TXT   | Text string | `"v=spf1 ..."` |
| SRV   | `priority weight port target` | `10 5 5060 sip.example.com.` |
| CAA   | `flags tag value` | `0 issue "letsencrypt.org"` |

## Automatic Records

The following record types are auto-managed by Technitium and should NOT be defined in YAML:
- **SOA** - Start of Authority
- **NS** - Name Server records

## Workflow

### On Push to Main

When changes to `platform/dns/zones/**` are pushed to `main`:
1. Zone files are validated for YAML syntax and schema
2. Changes are synced to Technitium DNS server
3. Results are logged in the GitHub Actions summary

### On Pull Request

When a PR modifies zone files:
1. Zone files are validated
2. A dry-run shows what changes would be made (no actual changes applied)

### Manual Sync

Use the "Run workflow" button in GitHub Actions to:
- Sync a specific zone
- Run in dry-run mode to preview changes

## Local Testing

### Prerequisites

```bash
pip install pyyaml
```

### Dry Run

Preview changes without applying:

```bash
export TECHNITIUM_URL="http://10.10.201.72:5380"
export TECHNITIUM_USER="your-username"
export TECHNITIUM_PASS="your-password"

cd platform/dns
python scripts/sync-dns.py --zone wind.etherport.net --dry-run
```

### Apply Changes

```bash
python scripts/sync-dns.py --zone wind.etherport.net --apply
```

### Delete Unmanaged Records

To remove records that exist in Technitium but not in the YAML file:

```bash
python scripts/sync-dns.py --zone wind.etherport.net --apply --delete-unmanaged
```

⚠️ **Warning**: Use `--delete-unmanaged` with caution. It will remove any records not defined in your YAML file.

## GitHub Secrets Required

Configure these secrets in your GitHub repository:

| Secret | Description |
|--------|-------------|
| `TECHNITIUM_URL` | Base URL (e.g., `http://10.10.201.72:5380`) |
| `TECHNITIUM_USER` | API username |
| `TECHNITIUM_PASS` | API password |

## Adding a New Zone

1. Create a new YAML file in `zones/` named `{zone-name}.yaml`
2. Define the zone and records following the format above
3. Commit and push to `main`
4. The workflow will automatically create the records

**Note**: The zone must already exist in Technitium. This tool manages records, not zones themselves.

## Troubleshooting

### "Zone not found" error

The zone must exist in Technitium before records can be synced. Create the zone via the Technitium web UI first.

### "Invalid token" error

The API token has expired. Check that `TECHNITIUM_USER` and `TECHNITIUM_PASS` secrets are correct.

### Records not updating

1. Check that the zone name in YAML matches the zone in Technitium
2. Verify the record name doesn't include the zone suffix (use `www`, not `www.example.com`)
3. Check the GitHub Actions logs for detailed error messages
