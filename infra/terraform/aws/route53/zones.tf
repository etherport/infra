# Route53 Hosted Zones — DECOMMISSIONED 2026-05-27
#
# All zones migrated to Cloudflare:
#   etherport.net      → CF zone (since CF Tunnel migration, see ../../cloudflare/)
#   grahamsmith.net    → CF zone (../../cloudflare-personal/grahamsmith.tf)
#   aws.etherport.net  → DELETED (private zone, never had real content)
#
# This module is now effectively empty. Leave the file (and outputs.tf,
# variables.tf, backend.tf) in place as historical context + so the
# S3 state file remains addressable. Files records-etherport.tf and
# records-grahamsmith.tf were deleted in the same commit.
#
# To fully decom: `cd .. && rm -rf route53/` (after confirming the
# state file in s3://terraform.wind.etherport.net/aws/route53/* is
# truly empty post-destroy).
