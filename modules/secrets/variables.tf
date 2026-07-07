variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "client_name" {
  description = "Name of the client"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
}

# Secrets Manager Configuration
variable "secrets" {
  description = "Map of secrets to create in Secrets Manager"
  type = map(object({
    description   = optional(string)
    secret_string = optional(string)
  }))
  default = {}
}

variable "kms_key_id" {
  description = "KMS key ID for encrypting secrets (uses AWS managed key if not specified)"
  type        = string
  default     = null
}

variable "recovery_window_in_days" {
  description = "Number of days that AWS Secrets Manager waits before it can delete the secret. Set to 0 for immediate deletion."
  type        = number
  default     = 0
}

variable "force_overwrite_replica_secret" {
  description = "Force overwrite a secret with the same name in the destination region"
  type        = bool
  default     = false
}

variable "replica_regions" {
  description = "List of regions to replicate secrets to"
  type = list(object({
    region     = string
    kms_key_id = optional(string)
  }))
  default = []
}

# External Secrets Operator Configuration
variable "deploy_external_secrets_operator" {
  description = "Deploy External Secrets Operator via Helm"
  type        = bool
  default     = true
}

variable "external_secrets_namespace" {
  description = "Namespace for External Secrets Operator"
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_version" {
  description = "Version of External Secrets Operator Helm chart"
  type        = string
  default     = "0.9.13"
}

variable "create_cluster_secret_store" {
  description = "Create ClusterSecretStore resources"
  type        = bool
  default     = true
}

variable "enable_ssm_provider" {
  description = "Enable AWS Parameter Store provider"
  type        = bool
  default     = true
}

variable "secrets_access_pattern" {
  description = "ARN pattern for secrets access (defaults to cluster-specific prefix)"
  type        = string
  default     = null
}

variable "ssm_access_pattern" {
  description = "ARN pattern for SSM parameters access (defaults to cluster-specific prefix)"
  type        = string
  default     = null
}

variable "helm_values" {
  description = "Additional Helm values for External Secrets Operator as YAML string"
  type        = string
  default     = null
}

# SSM Parameters Configuration
variable "ssm_parameters" {
  description = "Map of SSM parameters to create"
  type = map(object({
    description = optional(string)
    type        = optional(string)
    value       = string
    tier        = optional(string)
  }))
  default = {}
}

# Secrets Store CSI Driver Configuration (alternative)
variable "deploy_secrets_store_csi_driver" {
  description = "Deploy Secrets Store CSI Driver via Helm"
  type        = bool
  default     = false
}

variable "secrets_store_csi_driver_version" {
  description = "Version of Secrets Store CSI Driver Helm chart"
  type        = string
  default     = "1.4.2"
}

variable "aws_secrets_provider_version" {
  description = "Version of AWS Secrets Provider Helm chart"
  type        = string
  default     = "0.3.6"
}

variable "enable_secret_rotation" {
  description = "Enable secret rotation for CSI driver"
  type        = bool
  default     = true
}

variable "rotation_poll_interval" {
  description = "Interval for secret rotation polling"
  type        = string
  default     = "2m"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
