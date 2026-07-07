output "efs_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.main.id
}

output "efs_arn" {
  description = "ARN of the EFS file system"
  value       = aws_efs_file_system.main.arn
}

output "efs_dns_name" {
  description = "DNS name of the EFS file system"
  value       = aws_efs_file_system.main.dns_name
}

output "efs_security_group_id" {
  description = "Security group ID for EFS mount targets"
  value       = aws_security_group.efs.id
}

output "mount_target_ids" {
  description = "IDs of the EFS mount targets"
  value       = aws_efs_mount_target.main[*].id
}

output "mount_target_dns_names" {
  description = "DNS names of the EFS mount targets"
  value       = aws_efs_mount_target.main[*].dns_name
}

output "mount_target_ips" {
  description = "IP addresses of the EFS mount targets"
  value       = aws_efs_mount_target.main[*].ip_address
}

output "access_point_id" {
  description = "ID of the EFS access point"
  value       = var.create_access_point ? aws_efs_access_point.main[0].id : null
}

output "access_point_arn" {
  description = "ARN of the EFS access point"
  value       = var.create_access_point ? aws_efs_access_point.main[0].arn : null
}

output "efs_csi_driver_role_arn" {
  description = "ARN of the EFS CSI driver IAM role"
  value       = var.deploy_efs_csi_driver ? aws_iam_role.efs_csi_driver[0].arn : null
}

output "storage_class_name" {
  description = "Name of the EFS storage class"
  value       = var.create_storage_class ? kubernetes_storage_class.efs[0].metadata[0].name : null
}

output "persistent_volume_name" {
  description = "Name of the static PersistentVolume"
  value       = var.create_persistent_volume ? kubernetes_persistent_volume.efs[0].metadata[0].name : null
}

output "helm_release_name" {
  description = "Name of the EFS CSI driver Helm release"
  value       = var.deploy_efs_csi_driver ? helm_release.efs_csi_driver[0].name : null
}

output "helm_release_version" {
  description = "Version of the EFS CSI driver Helm release"
  value       = var.deploy_efs_csi_driver ? helm_release.efs_csi_driver[0].version : null
}
