output "role_arn" {
  description = "ARN to put in CI workflows as role-to-assume."
  value       = aws_iam_role.gh_actions_terraform.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
