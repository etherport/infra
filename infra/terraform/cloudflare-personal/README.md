# cloudflare-personal — auxiliary domain zones in CF

Manages the 3 personal/forwarding domains that previously lived in
Route53. Migrating saves $0.50/mo per zone ($1.50/mo total, $18/yr) and
puts everything in one DNS provider.

## Zones managed

| Zone | Purpose |
|---|---|
| `grahamsmith.net` | Email forwarding only (5 addresses) |
| `smithforsb.com` | Static site (CloudFront) + email forwarding (3 addresses) |
| `stopthecastle.com` | Static site (CloudFront, root + www) + email forwarding (1 address) |

## Records preserved across migration

- SES inbound MX (all)
- SES SPF, DKIM (3 CNAMEs each), DMARC, _amazonses verification
- ACM validation CNAMEs (preserve cert auto-renewal)
- Static site CloudFront ALIAS (rewritten as CF apex CNAME flat)
- Google Search Console verification (stopthecastle only)
- `mail.` subdomain MX + SPF (grahamsmith, stopthecastle — SES feedback)

## Records dropped

- `autodiscover.` CNAMEs (Outlook autodiscovery — no longer used)
- `vpn.grahamsmith.net` A (35.161.127.152, migrated)
- `windtryst.grahamsmith.net` CNAME → wind.gmsmeg.net (gmsmeg.net deprecated; SIP now reaches the UDM via sip.wind.etherport.net)
- `_4239d363....grahamsmith.net` CNAME (validation for orphan ACM cert
  `*.grahamsmith.net` — cert deleted as part of this migration)
- `scph1023._domainkey.smithforsb.com` TXT (legacy SendGrid DKIM)

## Migration procedure (manual + TF)

For each domain:

1. **In CF dashboard**: Add a site → enter domain → pick Free plan.
   CF assigns two nameservers (`<word1>.ns.cloudflare.com` /
   `<word2>.ns.cloudflare.com`). Copy zone ID.

2. **Update tfvars** (gitignored) with the zone ID:
   ```hcl
   grahamsmith_zone_id   = "...32-hex..."
   smithforsb_zone_id    = "...32-hex..."
   stopthecastle_zone_id = "...32-hex..."
   ```

3. **`terraform apply`** — creates all records in CF (still inactive
   externally until NS flip).

4. **In the registrar (Route53 Registrar for these)**: edit name
   servers for the domain to the 2 CF nameservers. Propagation:
   typically 5-10 min, max 48h.

5. **Verify**: `dig +short NS <domain>` returns the CF NS. Test a
   forwarded address (`echo "test" | mail g@grahamsmith.net` or
   equivalent — should arrive at the forwarder destination).

6. **Once verified**, decom the Route53 zone via TF:
   - `cd ../aws/route53` + remove the relevant records-*.tf entries +
     `terraform apply` (destroys the records + zone).
   - For smithforsb/stopthecastle (not in TF today): just delete the
     Route53 zone via console after CF takes over.

## Why CF apex CNAME instead of Route53 ALIAS

AWS Route53 has ALIAS records that point a name to AWS resources
(CloudFront, ALB, etc.) at the DNS-protocol level. Standard DNS doesn't
allow CNAME at the apex of a zone. CF's "CNAME flattening" feature does
the same logical thing using standard CNAME syntax — at lookup time CF
resolves the target and returns the resulting A/AAAA records, so apex
points to CloudFront just like the old ALIAS did.

## ACM cert continuity

ACM auto-renewal works by leaving the validation CNAME in DNS forever.
Migrating DNS to CF would normally break this UNLESS the validation
CNAME is preserved in the new zone. Both `*.smithforsb.com` (us-east-1)
and `stopthecastle.com` (us-east-1) certs are InUse=true by CloudFront,
so we need to keep their validation records or risk losing the cert at
next renewal (~12 months out, but better to preserve).

For `*.grahamsmith.net`: cert is ISSUED but InUseBy=[] (orphan after
ALB destroy 2026-05-27). Delete the cert + skip its validation CNAME
in the migration.
