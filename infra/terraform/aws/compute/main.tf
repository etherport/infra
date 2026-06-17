# AWS Compute Infrastructure
# Manages EC2 instances, EBS volumes, Elastic IPs, and related resources

locals {
  common_tags = {
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }

  # Cloud-init payload shared by both AWS VMs (vpn + dns). Appends the
  # gh-runner's automation pubkey to ubuntu's authorized_keys so the
  # ansible-vm-fleet workflow can SSH in without a manual key push.
  # Runs only on first boot — has no effect on a running instance, and
  # both `aws_instance` blocks `ignore_changes = [user_data]` so a
  # source diff doesn't try to recreate them.
  #
  # If the homelab automation key is ever rotated (1Password item
  # "Homelab Automation SSH Key"), update the pubkey here AND in
  # `infra/ansible/playbooks/pve-sshd.yml` AND on the live AWS hosts
  # (~ubuntu/.ssh/authorized_keys on dns-aws + vpn-aws). See
  # `memory/reference_pve_automation_pubkey.md` for the canonical
  # list of placement.
  aws_vm_cloud_init = <<-EOT
    #cloud-config
    users:
      - name: ubuntu
        ssh_authorized_keys:
          - "${var.automation_ssh_pubkey}"
  EOT
}

#------------------------------------------------------------------------------
# Data Sources - Reference networking module outputs
#------------------------------------------------------------------------------

data "aws_vpc" "private_infra" {
  id = var.vpc_id
}

data "aws_subnet" "public1" {
  id = var.public_subnet_id
}

data "aws_security_group" "vpn_server" {
  id = var.sg_vpn_server_id
}

data "aws_security_group" "dns_server" {
  id = var.sg_dns_server_id
}

data "aws_security_group" "internal_comms" {
  id = var.sg_internal_comms_id
}

data "aws_security_group" "allow_ssh" {
  id = var.sg_allow_ssh_id
}

#------------------------------------------------------------------------------
# IAM Role and Instance Profile for CloudWatch Agent
#------------------------------------------------------------------------------

resource "aws_iam_role" "ec2_cloudwatch_agent" {
  name        = "ec2-cloudwatch-agent"
  description = "IAM role for EC2 instances running CloudWatch agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "ec2-cloudwatch-agent"
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_cloudwatch_agent" {
  name = "ec2-cloudwatch-agent"
  role = aws_iam_role.ec2_cloudwatch_agent.name

  tags = merge(local.common_tags, {
    Name = "ec2-cloudwatch-agent"
  })
}

#------------------------------------------------------------------------------
# Key Pair
#------------------------------------------------------------------------------

# Note: Key pair is imported - we don't manage the private key in Terraform
resource "aws_key_pair" "gs_ec2" {
  key_name   = "GS-EC2"
  public_key = var.gs_ec2_public_key

  tags = merge(local.common_tags, {
    Name = "GS-EC2"
  })

  lifecycle {
    # Prevent accidental replacement of key pair
    prevent_destroy = true
  }
}

#------------------------------------------------------------------------------
# VPN Instance
#------------------------------------------------------------------------------

resource "aws_instance" "vpn" {
  ami                  = "ami-0acefc55c3a331fa8"
  instance_type        = "t4g.nano"
  key_name             = aws_key_pair.gs_ec2.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_cloudwatch_agent.name
  subnet_id            = data.aws_subnet.public1.id
  private_ip           = "10.10.100.10"

  # Cloud-init payload — runs ONCE on first boot to append the
  # homelab-automation pubkey to ubuntu's authorized_keys so the
  # gh-runner can ansible this host without a manual SSH key push.
  # (2026-05-23: discovered both AWS VMs were provisioned with only
  # the personal GS-EC2 key; the automation pubkey was added manually
  # post-hoc via SSH-from-laptop. This bakes the fix for any future
  # recreate.) Has no effect on the existing running instance.
  user_data = local.aws_vm_cloud_init

  vpc_security_group_ids = [
    data.aws_security_group.vpn_server.id,
    data.aws_security_group.internal_comms.id,
    data.aws_security_group.allow_ssh.id,
  ]

  # VPN needs source/dest check disabled for routing
  source_dest_check = false

  # IMDSv2 required
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, {
      Name = "private-infra_vpn_vol"
    })
  }

  tags = merge(local.common_tags, {
    Name = "private-infra_vpn"
  })

  lifecycle {
    # Prevent accidental destruction
    prevent_destroy = true
    # Ignore AMI + user_data changes — AMI upgrades are manual; user_data
    # only matters on first boot (cloud-init), so changes shouldn't
    # trigger replacement on an already-running instance.
    ignore_changes = [ami, user_data]
  }
}

#------------------------------------------------------------------------------
# DNS Instance
#------------------------------------------------------------------------------

resource "aws_instance" "dns" {
  ami                  = "ami-0acefc55c3a331fa8"
  instance_type        = "t4g.nano"
  key_name             = aws_key_pair.gs_ec2.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_cloudwatch_agent.name
  subnet_id            = data.aws_subnet.public1.id
  private_ip           = "10.10.100.5"

  # Same cloud-init payload as vpn-aws — see comment on aws_instance.vpn.
  user_data = local.aws_vm_cloud_init

  vpc_security_group_ids = [
    data.aws_security_group.dns_server.id,
    data.aws_security_group.internal_comms.id,
    data.aws_security_group.allow_ssh.id,
  ]

  # DNS instance keeps default source/dest check
  source_dest_check = true

  # IMDSv2 required
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, {
      Name = "private-infra_dns_vol"
    })
  }

  tags = merge(local.common_tags, {
    Name = "private-infra_dns"
  })

  lifecycle {
    # Prevent accidental destruction
    prevent_destroy = true
    # Ignore AMI + user_data — see comment on aws_instance.vpn.
    ignore_changes = [ami, user_data]
  }
}

#------------------------------------------------------------------------------
# Elastic IPs
#------------------------------------------------------------------------------

resource "aws_eip" "vpn" {
  domain   = "vpc"
  instance = aws_instance.vpn.id

  tags = merge(local.common_tags, {
    Name = "private-infra_vpn_ip"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "dns" {
  domain   = "vpc"
  instance = aws_instance.dns.id

  tags = merge(local.common_tags, {
    Name = "private-infra_dns_ip"
  })

  lifecycle {
    prevent_destroy = true
  }
}
