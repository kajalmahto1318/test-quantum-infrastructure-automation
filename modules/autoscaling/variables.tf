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

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
}

variable "node_iam_role_arn" {
  description = "ARN of the IAM role for EKS nodes"
  type        = string
}

variable "karpenter_namespace" {
  description = "Namespace for Karpenter"
  type        = string
  default     = "karpenter"
}

variable "karpenter_version" {
  description = "Version of Karpenter Helm chart"
  type        = string
  default     = "0.37.0"
}

variable "deploy_karpenter" {
  description = "Whether to deploy Karpenter via Helm"
  type        = bool
  default     = true
}

variable "controller_cpu_request" {
  description = "CPU request for Karpenter controller"
  type        = string
  default     = "100m"
}

variable "controller_memory_request" {
  description = "Memory request for Karpenter controller"
  type        = string
  default     = "256Mi"
}

variable "controller_cpu_limit" {
  description = "CPU limit for Karpenter controller"
  type        = string
  default     = "1"
}

variable "controller_memory_limit" {
  description = "Memory limit for Karpenter controller"
  type        = string
  default     = "1Gi"
}

variable "controller_replicas" {
  description = "Number of Karpenter controller replicas"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# NodePool and EC2NodeClass Variables
# =============================================================================

variable "node_iam_role_name" {
  description = "Name of the IAM role for EKS nodes (used by EC2NodeClass)"
  type        = string
}

variable "create_default_nodepool" {
  description = "Whether to create the default NodePool and EC2NodeClass"
  type        = bool
  default     = true
}

variable "ami_family" {
  description = "AMI family for Karpenter nodes"
  type        = string
  default     = "AL2"
}

variable "node_volume_size" {
  description = "Root volume size for Karpenter nodes in GB"
  type        = number
  default     = 50
}

variable "node_volume_type" {
  description = "Root volume type for Karpenter nodes"
  type        = string
  default     = "gp3"
}

variable "node_user_data" {
  description = "Custom user data for Karpenter nodes"
  type        = string
  default     = ""
}

variable "architectures" {
  description = "Allowed CPU architectures for instances"
  type        = list(string)
  default     = ["amd64"]
}

variable "capacity_types" {
  description = "Allowed capacity types (spot, on-demand)"
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "instance_categories" {
  description = "Allowed instance categories"
  type        = list(string)
  default     = ["c", "m", "r", "t"]
}

variable "instance_cpu_values" {
  description = "Allowed instance CPU values"
  type        = list(string)
  default     = ["2", "4", "8", "16", "32"]
}

variable "min_instance_memory" {
  description = "Minimum instance memory in MiB"
  type        = string
  default     = "2048"
}

variable "nodepool_labels" {
  description = "Additional labels to apply to nodes in the NodePool"
  type        = map(string)
  default     = {}
}

variable "nodepool_taints" {
  description = "Taints to apply to nodes in the NodePool"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "max_pods_per_node" {
  description = "Maximum number of pods per node"
  type        = number
  default     = 110
}

variable "nodepool_cpu_limit" {
  description = "Maximum total CPU cores Karpenter can provision"
  type        = string
  default     = "1000"
}

variable "nodepool_memory_limit" {
  description = "Maximum total memory Karpenter can provision"
  type        = string
  default     = "1000Gi"
}

variable "consolidation_policy" {
  description = "Consolidation policy: WhenEmpty or WhenUnderutilized"
  type        = string
  default     = "WhenEmpty"
}

variable "consolidate_after" {
  description = "Time after which to consolidate empty nodes (for WhenEmpty policy)"
  type        = string
  default     = "120s"
}

variable "disruption_budget_nodes" {
  description = "Percentage or number of nodes that can be disrupted at once"
  type        = string
  default     = "10%"
}

variable "nodepool_weight" {
  description = "Scheduling priority weight for this NodePool (higher = preferred)"
  type        = number
  default     = 10
}
