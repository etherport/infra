# Data Lifecycle Manager - EBS Snapshot Policy
#
# NOTE: The DLM policy (policy-00301f06dbf98ab54) is managed outside of Terraform.
# This is because the existing policy uses AWS's "SIMPLIFIED" policy language format,
# which is not supported by the Terraform AWS provider. The provider only supports
# the standard format with explicit schedules.
#
# Policy Details:
#   - Policy ID: policy-00301f06dbf98ab54
#   - Description: Daily EBS Backup
#   - Creates: Daily snapshots of all EBS volumes
#   - Retention: 7 days
#   - Copy Tags: Enabled
#
# The snapshot-archive Lambda references this policy ID for snapshot management.
