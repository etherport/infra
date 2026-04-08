variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "s3_bucket_name" {
  description = "S3 bucket name for email storage"
  type        = string
  default     = "email-fwd.grahamsmith.net"
}

variable "verified_sender" {
  description = "Verified SES sender email address"
  type        = string
  default     = "g@grahamsmith.net"
}

variable "graham_forward_to" {
  description = "Email address to forward graham's emails to"
  type        = string
  default     = "grahamsm@gmail.com"
}

variable "mark_forward_to" {
  description = "Email address to forward mark's emails to"
  type        = string
  default     = "mgoodwin.us@gmail.com"
}

