variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "client_name" {
  description = "Name of the client"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where EFS will be created"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for EFS mount targets"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group ID of EKS nodes"
  type        = string
}

variable "cluster_primary_security_group_id" {
  description = "Primary security group ID of EKS cluster (auto-created by EKS, attached to all nodes)"
  type        = string
  default     = null
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
}

# EFS Configuration
variable "encrypted" {
  description = "Whether to encrypt the EFS file system"
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "KMS key ID for encryption (uses AWS managed key if not specified)"
  type        = string
  default     = null
}

variable "performance_mode" {
  description = "Performance mode of the file system (generalPurpose or maxIO)"
  type        = string
  default     = "generalPurpose"
}

variable "throughput_mode" {
  description = "Throughput mode for the file system (bursting, provisioned, or elastic)"
  type        = string
  default     = "bursting"
}

variable "provisioned_throughput_in_mibps" {
  description = "Provisioned throughput in MiB/s (only valid if throughput_mode is provisioned)"
  type        = number
  default     = null
}

variable "lifecycle_policy_transition_to_ia" {
  description = "Transition files to IA storage class after specified period"
  type        = string
  default     = "AFTER_30_DAYS"
}

variable "lifecycle_policy_transition_to_primary_storage_class" {
  description = "Transition files back to primary storage class on access"
  type        = string
  default     = "AFTER_1_ACCESS"
}

variable "enable_backup" {
  description = "Enable automatic backups"
  type        = bool
  default     = true
}

# Access Point Configuration
variable "create_access_point" {
  description = "Create an EFS access point"
  type        = bool
  default     = true
}

variable "access_point_uid" {
  description = "POSIX user ID for access point"
  type        = number
  default     = 1000
}

variable "access_point_gid" {
  description = "POSIX group ID for access point"
  type        = number
  default     = 1000
}

variable "access_point_root_path" {
  description = "Root directory path for access point"
  type        = string
  default     = "/data"
}

variable "access_point_permissions" {
  description = "POSIX permissions for access point root directory"
  type        = string
  default     = "755"
}

# CSI Driver Configuration
variable "deploy_efs_csi_driver" {
  description = "Deploy EFS CSI driver via Helm"
  type        = bool
  default     = true
}

variable "efs_csi_driver_version" {
  description = "Version of EFS CSI driver Helm chart"
  type        = string
  default     = "3.0.0"
}

# Storage Class Configuration
variable "create_storage_class" {
  description = "Create a StorageClass for EFS"
  type        = bool
  default     = true
}

variable "make_default_storage_class" {
  description = "Make EFS storage class the default"
  type        = bool
  default     = false
}

variable "storage_class_reclaim_policy" {
  description = "Reclaim policy for the storage class"
  type        = string
  default     = "Delete"
}

variable "storage_class_directory_perms" {
  description = "Directory permissions for dynamically provisioned volumes"
  type        = string
  default     = "700"
}

variable "storage_class_base_path" {
  description = "Base path for dynamically provisioned volumes"
  type        = string
  default     = "/dynamic_provisioning"
}

variable "storage_class_mount_options" {
  description = "Mount options for the storage class"
  type        = list(string)
  default     = []
}

# Persistent Volume Configuration
variable "create_persistent_volume" {
  description = "Create a static PersistentVolume"
  type        = bool
  default     = true
}

variable "pv_capacity" {
  description = "Capacity for the static PV"
  type        = string
  default     = "100Gi"
}

variable "pv_access_modes" {
  description = "Access modes for the PV"
  type        = list(string)
  default     = ["ReadWriteMany"]
}

variable "pv_reclaim_policy" {
  description = "Reclaim policy for the PV"
  type        = string
  default     = "Retain"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# PVC variables
variable "pvc_name" {
  description = "Name of the PersistentVolumeClaim"
  type        = string
  default     = "efs-quantum-pvc"
}

variable "pvc_namespace" {
  description = "Namespace for the PersistentVolumeClaim"
  type        = string
  default     = "argo"
}

variable "pvc_size" {
  description = "Requested size for the PersistentVolumeClaim"
  type        = string
  default     = "5Gi"
}
