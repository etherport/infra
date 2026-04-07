# AWS Compute Infrastructure
# Manages EC2 instances, EBS volumes, Elastic IPs, and related resources

locals {
  common_tags = {
    Environment = "homelab"
    ManagedBy   = "terraform"
    Module      = "compute"
  }
}

#------------------------------------------------------------------------------
# Data Sources - Reference networking module outputs
#------------------------------------------------------------------------------

data "aws_vpc" "private_infra" {
  id = "vpc-0cf7cb3b71fc48958"
}

data "aws_subnet" "public1" {
  id = "subnet-05df0a901053021dd"
}

data "aws_security_group" "vpn_server" {
  id = "sg-08323ff8e98ecb563"
}

data "aws_security_group" "dns_server" {
  id = "sg-08d12e417159c18d2"
}

data "aws_security_group" "internal_comms" {
  id = "sg-0c882ffea5692bd63"
}

data "aws_security_group" "allow_ssh" {
  id = "sg-0079fee23ee54417a"
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
    encrypted             = false

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
    # Ignore AMI changes - upgrades are manual
    ignore_changes = [ami]
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
    encrypted             = false

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
    # Ignore AMI changes - upgrades are manual
    ignore_changes = [ami]
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
