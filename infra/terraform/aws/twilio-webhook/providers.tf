terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# us-west-2 keeps the Lambda in-region with SES (where the verified
# domain + DKIM CNAMEs live, per the etherport.net CF zone).
provider "aws" {
  region  = "us-west-2"
  profile = var.aws_profile != "" ? var.aws_profile : null
}
