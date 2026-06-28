# The three ARNs the mini's aws_signing_helper credential_process needs
# (see docs/runbooks/aws-roles-anywhere-mini.md).

output "trust_anchor_arn" {
  description = "RA trust anchor ARN (--trust-anchor-arn)"
  value       = aws_rolesanywhere_trust_anchor.wind.arn
}

output "profile_arn" {
  description = "RA profile ARN (--profile-arn)"
  value       = aws_rolesanywhere_profile.mini.arn
}

output "role_arn" {
  description = "IAM role the mini assumes (--role-arn)"
  value       = aws_iam_role.mini_ra.arn
}
