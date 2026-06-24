# Outputs for cluster-irsa module (M75)

output "issuer_url" {
  description = "OIDC issuer URL — set the kube-apiserver --service-account-issuer to this (M75 Phase 3)."
  value       = local.issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the cluster issuer."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "role_arns" {
  description = "Map of workload -> IRSA role ARN. Annotate each ServiceAccount with eks.amazonaws.com/role-arn = its ARN (M75 Phase 4)."
  value       = { for k, r in aws_iam_role.irsa : k => r.arn }
}
