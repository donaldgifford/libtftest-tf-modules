#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers + PV manifest references.
#--------------------------------------------------------------

output "filesystem_id" {
  description = "EFS filesystem ID. Plugs into the volumeHandle field of a PV manifest — either as the bare ID (root-mount PVs) or as the <filesystem_id>::<access_point_id> shape (access-point-scoped PVs)."
  value       = aws_efs_file_system.this.id
}

output "filesystem_arn" {
  description = "EFS filesystem ARN. Consumed by IAM policies scoped to this specific filesystem (elasticfilesystem:ClientMount / ClientWrite / ClientRootAccess resource segments)."
  value       = aws_efs_file_system.this.arn
}

output "dns_name" {
  description = "DNS hostname of the filesystem (<fs-id>.efs.<region>.amazonaws.com). Used by non-CSI NFS clients (EC2 instances, batch jobs) that mount the filesystem directly via /etc/fstab or mount(8). EFS CSI driver consumers use filesystem_id instead."
  value       = aws_efs_file_system.this.dns_name
}

output "mount_target_ids" {
  description = "Map of subnet ID → mount target ID. Useful for operators inspecting mount-target state via the AWS CLI; not typically consumed by Terraform downstream."
  value       = { for k, mt in aws_efs_mount_target.this : k => mt.id }
}

output "mount_target_dns_names" {
  description = "Map of subnet ID → mount target DNS name. Useful for diagnosing per-AZ mount issues."
  value       = { for k, mt in aws_efs_mount_target.this : k => mt.dns_name }
}

output "security_group_id" {
  description = "Mount-target security group ID. Consumers can reference this when they add their own peering ingress rules outside the module's additional_allowed_consumer_sg_ids contract (e.g., for cross-VPC consumers reachable via a transit gateway)."
  value       = aws_security_group.this.id
}

output "kms_key_arn" {
  description = "KMS key ARN encrypting filesystem data at rest. BYO ARN (when var.kms_key_arn was non-null) or module-managed key's ARN — resolved transparently via local.kms_key_arn."
  value       = local.kms_key_arn
}

output "access_point_ids" {
  description = "Map of access-point logical name (var.access_points map key) → access point ID. Plugs into the second segment of the <filesystem_id>::<access_point_id> volumeHandle shape on PV manifests."
  value       = { for k, ap in aws_efs_access_point.this : k => ap.id }
}

output "access_point_arns" {
  description = "Map of access-point logical name → access point ARN. Consumed by IAM policies scoping elasticfilesystem:ClientMount permissions to a specific access point."
  value       = { for k, ap in aws_efs_access_point.this : k => ap.arn }
}
