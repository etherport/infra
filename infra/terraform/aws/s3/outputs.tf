# Outputs for s3 module

output "velero_bucket_arn" {
  description = "ARN of the Velero backup bucket"
  value       = aws_s3_bucket.velero.arn
}

output "archive_bucket_arn" {
  description = "ARN of the snapshot archive bucket"
  value       = aws_s3_bucket.archive.arn
}

output "logs_archive_bucket_arn" {
  description = "ARN of the archive logs bucket"
  value       = aws_s3_bucket.logs_archive.arn
}

output "email_fwd_bucket_arn" {
  description = "ARN of the email forwarding bucket"
  value       = aws_s3_bucket.email_fwd.arn
}

output "logs_bucket_arn" {
  description = "ARN of the general logs bucket"
  value       = aws_s3_bucket.logs.arn
}

output "postgres_barman_bucket_arn" {
  description = "ARN of the postgres barman backup bucket"
  value       = aws_s3_bucket.postgres_barman.arn
}

output "etcd_snapshots_bucket_arn" {
  description = "ARN of the etcd snapshot offsite-DR bucket"
  value       = aws_s3_bucket.etcd_snapshots.arn
}

output "buckets" {
  description = "Map of all managed bucket names to ARNs"
  value = {
    velero          = aws_s3_bucket.velero.arn
    archive         = aws_s3_bucket.archive.arn
    logs_archive    = aws_s3_bucket.logs_archive.arn
    email_fwd       = aws_s3_bucket.email_fwd.arn
    logs            = aws_s3_bucket.logs.arn
    postgres_barman = aws_s3_bucket.postgres_barman.arn
    etcd_snapshots  = aws_s3_bucket.etcd_snapshots.arn
  }
}

#------------------------------------------------------------------------------
# Postgres Barman IAM access key (sensitive)
#
# Retrieve with:
#   cd infra/terraform/aws/s3
#   terraform output -raw postgres_barman_access_key_id
#   terraform output -raw postgres_barman_secret_access_key
#
# Then SOPS-encrypt into:
#   platform/kubernetes/cnpg/05-barman-credentials.sops.yaml
#------------------------------------------------------------------------------

output "postgres_barman_access_key_id" {
  description = "Access key ID for the barman-postgres IAM user"
  value       = aws_iam_access_key.postgres_barman.id
  sensitive   = true
}

output "postgres_barman_secret_access_key" {
  description = "Secret access key for the barman-postgres IAM user"
  value       = aws_iam_access_key.postgres_barman.secret
  sensitive   = true
}

#------------------------------------------------------------------------------
# etcd-backup IAM access key (sensitive) — M62
#
# Retrieve with:
#   cd infra/terraform/aws/s3
#   terraform output -raw etcd_backup_access_key_id
#   terraform output -raw etcd_backup_secret_access_key
#
# Then SOPS-encrypt into the etcd-backup ansible secret (see
# infra/ansible/playbooks/etcd-backup.yml) and distribute to the cp nodes.
#------------------------------------------------------------------------------

output "etcd_backup_access_key_id" {
  description = "Access key ID for the etcd-backup IAM user"
  value       = aws_iam_access_key.etcd_backup.id
  sensitive   = true
}

output "etcd_backup_secret_access_key" {
  description = "Secret access key for the etcd-backup IAM user"
  value       = aws_iam_access_key.etcd_backup.secret
  sensitive   = true
}
