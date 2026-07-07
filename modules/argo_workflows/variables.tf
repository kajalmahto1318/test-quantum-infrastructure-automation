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

# Argo Workflows Configuration
variable "deploy_argo_workflows" {
  description = "Whether to deploy Argo Workflows via Helm"
  type        = bool
  default     = true
}

variable "argo_namespace" {
  description = "Namespace for Argo Workflows"
  type        = string
  default     = "argo"
}

variable "argo_workflows_version" {
  description = "Version of Argo Workflows Helm chart"
  type        = string
  default     = "0.41.0"
}

variable "enable_argo_server" {
  description = "Enable Argo Workflows server (UI)"
  type        = bool
  default     = true
}

variable "server_service_type" {
  description = "Service type for Argo Workflows server (ClusterIP, LoadBalancer, or NodePort)"
  type        = string
  default     = "LoadBalancer"
}

variable "server_replicas" {
  description = "Number of Argo Workflows server replicas"
  type        = number
  default     = 1
}

variable "controller_replicas" {
  description = "Number of Argo Workflows controller replicas"
  type        = number
  default     = 1
}

variable "enable_metrics" {
  description = "Enable Prometheus metrics"
  type        = bool
  default     = true
}

variable "enable_workflow_archive" {
  description = "Enable workflow archiving"
  type        = bool
  default     = false
}

variable "helm_values" {
  description = "Additional Helm values for Argo Workflows as YAML string"
  type        = string
  default     = null
}

# S3 Artifact Repository
variable "enable_s3_artifact_repository" {
  description = "Enable S3 as artifact repository"
  type        = bool
  default     = true
}

variable "artifact_retention_days" {
  description = "Number of days to retain artifacts in S3"
  type        = number
  default     = 30
}

# Admin ServiceAccount Configuration
variable "create_admin_service_account" {
  description = "Create an admin ServiceAccount with full access to Argo Workflows"
  type        = bool
  default     = true
}

variable "store_token_in_secrets_manager" {
  description = "Store the admin ServiceAccount token in AWS Secrets Manager"
  type        = bool
  default     = true
}

variable "nodegroup_name" {
  description = "Name of the EKS managed node group to schedule Argo components on (to avoid Karpenter nodes)"
  type        = string
  default     = ""
}

variable "protect_workflow_pods_from_disruption" {
  description = "Add karpenter.sh/do-not-disrupt annotation to workflow pods to prevent Karpenter from terminating nodes while workflows are running"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
