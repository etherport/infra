# config-recorder — per-region AWS Config recorder + delivery channel + status.
# The region is whatever aws provider the caller passes (default for us-west-2,
# aws.use1 for us-east-1).
#
# APPLY ORDER (Config is strict; out-of-order create fails):
#   1. configuration_recorder        (WHAT to record + the role)
#   2. delivery_channel              (WHERE to deliver)  -- depends_on recorder
#   3. configuration_recorder_status (START it)          -- depends_on channel
# Terraform won't infer 1->2->3 from references alone, so depends_on are explicit.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "role_arn" {
  description = "ARN of the shared Config service role (config.amazonaws.com)."
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the shared S3 delivery bucket."
  type        = string
}

variable "include_global_resources" {
  description = "Record global resource types (IAM, CloudFront, etc.). TRUE in exactly ONE region to avoid double-recording/billing."
  type        = bool
  default     = false
}

variable "recorder_name" {
  description = "Name of the configuration recorder + delivery channel."
  type        = string
  default     = "default"
}

# 1) WHAT to record: ALL supported types. include_global_resource_types is only
#    meaningful with all_supported=true; set TRUE in one region only.
#    recording_frequency = DAILY keeps cost at ~$0.003/item/day, not per-change.
#    ⚠️ If a future apply 400s on a specific type that AWS won't record DAILY,
#    add a `recording_mode_override { recording_frequency = "CONTINUOUS",
#    resource_types = [...] }` here for just that type — do NOT flip the whole
#    recorder to CONTINUOUS (cost). Don't pre-add it; let the plan/apply reveal it.
resource "aws_config_configuration_recorder" "this" {
  name     = var.recorder_name
  role_arn = var.role_arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.include_global_resources
  }

  recording_mode {
    recording_frequency = "DAILY"
  }
}

# 2) WHERE to deliver. Snapshot cadence DAILY (matches recording).
resource "aws_config_delivery_channel" "this" {
  name           = var.recorder_name
  s3_bucket_name = var.s3_bucket_name

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

# 3) START recording. The channel MUST exist first.
resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

output "recorder_name" {
  value = aws_config_configuration_recorder.this.name
}
