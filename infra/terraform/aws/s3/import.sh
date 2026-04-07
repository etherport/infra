#!/bin/bash
# Import script for s3 module
# Run this after terraform init to import existing AWS resources

set -e

echo "=== Importing S3 Buckets ==="
echo ""

# Velero backups
echo "Importing velero bucket..."
terraform import aws_s3_bucket.velero velero.wind.etherport.net
terraform import aws_s3_bucket_versioning.velero velero.wind.etherport.net
terraform import aws_s3_bucket_lifecycle_configuration.velero velero.wind.etherport.net
terraform import aws_s3_bucket_public_access_block.velero velero.wind.etherport.net

# Archive
echo ""
echo "Importing archive bucket..."
terraform import aws_s3_bucket.archive archive.wind.etherport.net
terraform import aws_s3_bucket_versioning.archive archive.wind.etherport.net
terraform import aws_s3_bucket_lifecycle_configuration.archive archive.wind.etherport.net
terraform import aws_s3_bucket_public_access_block.archive archive.wind.etherport.net

# Logs archive
echo ""
echo "Importing logs archive bucket..."
terraform import aws_s3_bucket.logs_archive logs.archive.wind.etherport.net
terraform import aws_s3_bucket_versioning.logs_archive logs.archive.wind.etherport.net
terraform import aws_s3_bucket_lifecycle_configuration.logs_archive logs.archive.wind.etherport.net
terraform import aws_s3_bucket_public_access_block.logs_archive logs.archive.wind.etherport.net

# Email forwarding
echo ""
echo "Importing email forwarding bucket..."
terraform import aws_s3_bucket.email_fwd email-fwd.grahamsmith.net
terraform import aws_s3_bucket_lifecycle_configuration.email_fwd email-fwd.grahamsmith.net
terraform import aws_s3_bucket_public_access_block.email_fwd email-fwd.grahamsmith.net

# General logs
echo ""
echo "Importing logs bucket..."
terraform import aws_s3_bucket.logs logs.grahamsmith.net
terraform import aws_s3_bucket_policy.logs logs.grahamsmith.net
terraform import aws_s3_bucket_public_access_block.logs logs.grahamsmith.net

echo ""
echo "=== Import Complete ==="
echo ""
echo "Next steps:"
echo "1. Run 'terraform plan' to verify state matches configuration"
echo "2. If there are differences, adjust the Terraform config to match"
echo "3. Run 'terraform apply' to finalize"
