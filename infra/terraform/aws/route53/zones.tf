# Route53 Hosted Zones
# Homelab domains - etherport.net and grahamsmith.net

#------------------------------------------------------------------------------
# etherport.net - Primary homelab domain
#------------------------------------------------------------------------------

resource "aws_route53_zone" "etherport" {
  name    = "etherport.net"
  comment = "Primary homelab domain"

  lifecycle {
    prevent_destroy = true
  }
}

#------------------------------------------------------------------------------
# grahamsmith.net - Personal domain
#------------------------------------------------------------------------------

resource "aws_route53_zone" "grahamsmith" {
  name    = "grahamsmith.net"
  comment = "Personal domain"

  lifecycle {
    prevent_destroy = true
  }
}

#------------------------------------------------------------------------------
# aws.etherport.net - Private hosted zone for AWS-internal resources
#
# Naming convention: anything living natively in AWS (RDS endpoints,
# private LBs, EC2 hostname aliases) gets a record here. Convention is
# `*.etherport.net` (no wind prefix) — wind.etherport.net stays for
# homelab. `aws.` subdomain delineates without inventing a new TLD.
#
# This zone is private (associated with VPCs only) — not resolvable
# from the public internet. Resolved by AWS Route53 Resolver from
# within the VPC, and by the Resolver Inbound Endpoint from on-prem
# via the homelab→AWS VPN. Technitium forwards `*.aws.etherport.net`
# queries to the inbound endpoint (10.10.100.x — see runbook).
#------------------------------------------------------------------------------

# Look up the private_infra VPC managed in the networking module.
# Using a data lookup (not terraform_remote_state) so this module
# doesn't depend on networking's state file directly.
data "aws_vpc" "private_infra" {
  tags = {
    Name = "private-infra-vpc"
  }
}

resource "aws_route53_zone" "aws_etherport" {
  name    = "aws.etherport.net"
  comment = "Private hosted zone for AWS-internal homelab resources"

  vpc {
    vpc_id = data.aws_vpc.private_infra.id
  }

  lifecycle {
    prevent_destroy = true
  }
}
