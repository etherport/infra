variable "aws_region" {
  description = "AWS region (IAM is global; region is for the provider/backend)."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS profile; empty string = use env/role creds (CI)."
  type        = string
  default     = ""
}
