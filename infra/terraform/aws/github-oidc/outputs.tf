output "role_arn" {
  description = "ARN to put in the infra repo's CI workflows as role-to-assume."
  value       = aws_iam_role.gh_actions_terraform.arn
}

output "personal_web_role_arn" {
  description = "ARN to put in the personal-web repo's CI workflow as role-to-assume."
  value       = aws_iam_role.gh_actions_personal_web.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
