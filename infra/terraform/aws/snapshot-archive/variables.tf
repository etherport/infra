variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "archive_retention_days" {
  description = "Number of days to retain archived snapshots before deletion"
  type        = number
  default     = 90
}

variable "active_archive_interval" {
  description = "Minimum days between archiving snapshots for the same volume"
  type        = number
  default     = 5
}

variable "dlm_policy_id" {
  description = "DLM policy ID for reference"
  type        = string
  default     = "policy-00301f06dbf98ab54"
}

variable "ses_sender" {
  description = "Verified SES sender email address"
  type        = string
  default     = "g@grahamsmith.net"
}

variable "ses_recipient" {
  description = "Email recipient for snapshot summary"
  type        = string
  default     = "graham.m.smith@me.com"
}

variable "ses_subject" {
  description = "Email subject line"
  type        = string
  default     = "EC2 Snapshot Summary"
}

variable "ses_from_name" {
  description = "Friendly display name for the sender"
  type        = string
  default     = "EC2 Snapshot Updater"
}

variable "ses_reply_to" {
  description = "Reply-to email address"
  type        = string
  default     = "noreply@grahamsmith.net"
}

variable "schedule_expression" {
  description = "EventBridge schedule expression"
  type        = string
  default     = "cron(0 13 * * ? *)" # Daily at 1 PM UTC
}
