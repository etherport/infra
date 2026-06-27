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

output "attached_policy_count" {
  description = "How many managed policies are attached to the role (raise the per-role quota if >10)"
  value       = length(var.attached_policy_names)
}
