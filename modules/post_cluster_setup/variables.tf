# =============================================================================
# COMMON VARIABLES
# =============================================================================

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

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# CLUSTER CONNECTIVITY
# =============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint of the EKS cluster"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster is deployed"
  type        = string
}

variable "aws_access_key" {
  description = "AWS access key for CLI operations"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS secret key for CLI operations"
  type        = string
  sensitive   = true
}

# =============================================================================
# CLUSTER READINESS
# =============================================================================

variable "verify_cluster_readiness" {
  description = "Whether to verify cluster readiness before deploying resources"
  type        = bool
  default     = true
}

variable "cluster_readiness_wait_time" {
  description = "Time to wait before checking cluster readiness"
  type        = string
  default     = "30s"
}

variable "wait_for_karpenter" {
  description = "Whether to wait for Karpenter to be ready before deploying resources"
  type        = bool
  default     = true
}

variable "karpenter_namespace" {
  description = "Namespace where Karpenter is deployed"
  type        = string
  default     = "karpenter"
}

# =============================================================================
# NAMESPACE CONFIGURATION
# =============================================================================

variable "deploy_namespaces" {
  description = "Whether to deploy namespaces"
  type        = bool
  default     = true
}

variable "namespaces" {
  description = "List of namespaces to create"
  type        = list(string)
  default     = []
}

variable "namespace_labels" {
  description = "Map of namespace names to additional labels"
  type        = map(map(string))
  default     = {}
}

variable "namespace_annotations" {
  description = "Map of namespace names to annotations"
  type        = map(map(string))
  default     = {}
}

# =============================================================================
# RBAC CONFIGURATION
# =============================================================================

variable "create_admin_role" {
  description = "Whether to create a cluster admin role"
  type        = bool
  default     = true
}

variable "create_developer_role" {
  description = "Whether to create a developer role"
  type        = bool
  default     = true
}

variable "create_readonly_role" {
  description = "Whether to create a read-only role"
  type        = bool
  default     = true
}

# =============================================================================
# INGRESS CONTROLLER CONFIGURATION
# =============================================================================

variable "deploy_ingress_controller" {
  description = "Whether to deploy an ingress controller"
  type        = bool
  default     = true
}

variable "ingress_controller_type" {
  description = "Type of ingress controller to deploy (nginx or alb)"
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "alb"], var.ingress_controller_type)
    error_message = "Ingress controller type must be 'nginx' or 'alb'."
  }
}

variable "ingress_controller_namespace" {
  description = "Namespace for ingress controller"
  type        = string
  default     = "ingress-nginx"
}

variable "ingress_controller_replicas" {
  description = "Number of ingress controller replicas"
  type        = number
  default     = 2
}

variable "ingress_service_type" {
  description = "Service type for ingress controller (LoadBalancer or NodePort)"
  type        = string
  default     = "LoadBalancer"
}

variable "ingress_load_balancer_scheme" {
  description = "Load balancer scheme (internet-facing or internal)"
  type        = string
  default     = "internet-facing"
}

variable "ingress_service_annotations" {
  description = "Additional annotations for ingress service"
  type        = map(string)
  default     = {}
}

variable "ingress_controller_cpu_request" {
  description = "CPU request for ingress controller"
  type        = string
  default     = "100m"
}

variable "ingress_controller_memory_request" {
  description = "Memory request for ingress controller"
  type        = string
  default     = "256Mi"
}

variable "ingress_controller_cpu_limit" {
  description = "CPU limit for ingress controller"
  type        = string
  default     = "500m"
}

variable "ingress_controller_memory_limit" {
  description = "Memory limit for ingress controller"
  type        = string
  default     = "512Mi"
}

variable "enable_ingress_metrics" {
  description = "Whether to enable metrics for ingress controller"
  type        = bool
  default     = true
}

variable "enable_default_backend" {
  description = "Whether to enable default backend for NGINX"
  type        = bool
  default     = true
}

# NGINX Specific
variable "nginx_ingress_version" {
  description = "Version of NGINX ingress controller Helm chart"
  type        = string
  default     = "4.10.0"
}

variable "nginx_ingress_config" {
  description = "NGINX ingress controller config map settings"
  type        = map(string)
  default = {
    "proxy-body-size"       = "50m"
    "proxy-read-timeout"    = "300"
    "proxy-send-timeout"    = "300"
    "use-forwarded-headers" = "true"
  }
}

# ALB Specific
variable "alb_controller_version" {
  description = "Version of AWS Load Balancer Controller Helm chart"
  type        = string
  default     = "1.7.1"
}

# =============================================================================
# RESOURCE QUOTAS
# =============================================================================

variable "deploy_resource_quotas" {
  description = "Whether to deploy resource quotas"
  type        = bool
  default     = false
}

variable "resource_quotas" {
  description = "Map of namespace names to resource quota specifications"
  type        = map(map(string))
  default     = {}
  # Example:
  # {
  #   "dev" = {
  #     "requests.cpu"    = "10"
  #     "requests.memory" = "20Gi"
  #     "limits.cpu"      = "20"
  #     "limits.memory"   = "40Gi"
  #     "pods"            = "50"
  #   }
  # }
}

# =============================================================================
# LIMIT RANGES
# =============================================================================

variable "deploy_limit_ranges" {
  description = "Whether to deploy limit ranges"
  type        = bool
  default     = false
}

variable "limit_ranges" {
  description = "Map of namespace names to limit range specifications"
  type        = map(any)
  default     = {}
  # Example:
  # {
  #   "dev" = {
  #     "default" = {
  #       "cpu"    = "500m"
  #       "memory" = "512Mi"
  #     }
  #     "default_request" = {
  #       "cpu"    = "100m"
  #       "memory" = "128Mi"
  #     }
  #   }
  # }
}

# =============================================================================
# NETWORK POLICIES
# =============================================================================

variable "deploy_network_policies" {
  description = "Whether to deploy network policies"
  type        = bool
  default     = false
}

# =============================================================================
# POD SECURITY STANDARDS
# =============================================================================

variable "enforce_pod_security_standards" {
  description = "Whether to enforce Pod Security Standards on namespaces"
  type        = bool
  default     = false
}

variable "pod_security_level" {
  description = "Pod Security Standard level (privileged, baseline, or restricted)"
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.pod_security_level)
    error_message = "Pod security level must be 'privileged', 'baseline', or 'restricted'."
  }
}

# =============================================================================
# NODECLAIM CLEANER
# =============================================================================

variable "enable_nodeclaim_cleaner" {
  description = "Whether to deploy the NodeClaim cleaner that removes stuck/unready NodeClaims"
  type        = bool
  default     = true
}

variable "enable_karpenter" {
  description = "Whether Karpenter is enabled (NodeClaim cleaner depends on this)"
  type        = bool
  default     = true
}

variable "nodeclaim_cleaner_image" {
  description = "Docker image for the NodeClaim cleaner"
  type        = string
  default     = "bitnami/kubectl:latest"
}

variable "nodeclaim_cleaner_threshold_seconds" {
  description = "Age threshold in seconds after which unready NodeClaims will be deleted"
  type        = number
  default     = 100
}

variable "nodeclaim_cleaner_interval_seconds" {
  description = "Interval in seconds between NodeClaim cleanup runs"
  type        = number
  default     = 120
}

variable "nodeclaim_cleaner_cpu_request" {
  description = "CPU request for NodeClaim cleaner pod"
  type        = string
  default     = "50m"
}

variable "nodeclaim_cleaner_memory_request" {
  description = "Memory request for NodeClaim cleaner pod"
  type        = string
  default     = "64Mi"
}

variable "nodeclaim_cleaner_cpu_limit" {
  description = "CPU limit for NodeClaim cleaner pod"
  type        = string
  default     = "100m"
}

variable "nodeclaim_cleaner_memory_limit" {
  description = "Memory limit for NodeClaim cleaner pod"
  type        = string
  default     = "128Mi"
}

# =============================================================================
# KARPENTER MANIFESTS (EC2NodeClass & NodePool)
# =============================================================================

variable "create_karpenter_manifests" {
  description = "Whether to create Karpenter EC2NodeClass and NodePool manifests"
  type        = bool
  default     = false
}

variable "karpenter_nodeclass_name" {
  description = "Name for the Karpenter EC2NodeClass"
  type        = string
  default     = "default"
}

variable "karpenter_nodepool_name" {
  description = "Name for the Karpenter NodePool"
  type        = string
  default     = "default"
}

variable "karpenter_ami_family" {
  description = "AMI family for EC2NodeClass (AL2, BOTTLEROCKET, UBUNTU, WINDOWS2022, WINDOWS2019)"
  type        = string
  default     = "AL2"
}

variable "karpenter_subnet_ids" {
  description = "List of subnet IDs for Karpenter nodes"
  type        = list(string)
  default     = []
}

variable "karpenter_security_group_ids" {
  description = "List of security group IDs for Karpenter nodes"
  type        = list(string)
  default     = []
}

variable "karpenter_instance_profile_arn" {
  description = "Instance profile ARN for Karpenter nodes (node IAM role)"
  type        = string
  default     = ""
}

variable "karpenter_node_tags" {
  description = "Additional tags for Karpenter-provisioned nodes"
  type        = map(string)
  default = {
    "managed-by" = "karpenter"
  }
}

variable "karpenter_block_device_mappings" {
  description = "Block device mappings for Karpenter nodes"
  type = list(object({
    device_name = string
    ebs = optional(object({
      volume_size           = optional(number, 30)
      volume_type           = optional(string, "gp3")
      delete_on_termination = optional(bool, true)
      encrypted             = optional(bool, true)
    }))
  }))
  default = [
    {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = 30
        volume_type           = "gp3"
        delete_on_termination = true
        encrypted             = true
      }
    }
  ]
}

variable "karpenter_node_labels" {
  description = "Labels to apply to Karpenter-provisioned nodes"
  type        = map(string)
  default = {
    "managed-by" = "karpenter"
  }
}

variable "karpenter_node_taints" {
  description = "Taints to apply to Karpenter-provisioned nodes"
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = []
}

variable "karpenter_requirements" {
  description = "Karpenter NodePool requirements"
  type = list(object({
    key      = string
    operator = string
    values   = list(string)
  }))
  default = [
    {
      key      = "kubernetes.io/arch"
      operator = "In"
      values   = ["amd64"]
    },
    {
      key      = "karpenter.sh/capacity-type"
      operator = "In"
      values   = ["spot", "on-demand"]
    },
    {
      key      = "node.kubernetes.io/instance-type"
      operator = "In"
      values   = ["t3.medium", "t3.large", "m5.large", "m5.xlarge"]
    }
  ]
}

variable "karpenter_limits" {
  description = "Karpenter NodePool limits (cpu, memory)"
  type = object({
    cpu    = optional(string, "1000")
    memory = optional(string, "1000Gi")
  })
  default = {}
}

variable "karpenter_consolidation_policy" {
  description = "Consolidation policy for Karpenter (WhenUnderutilized, WhenUnderutilizedAndUnderutilized, etc.)"
  type        = string
  default     = "WhenUnderutilized"
}

variable "karpenter_consolidate_after" {
  description = "Time to wait before consolidating nodes"
  type        = string
  default     = "30s"
}

variable "karpenter_expire_after" {
  description = "Time after which nodes expire and are terminated"
  type        = string
  default     = "720h"
}

variable "karpenter_disruption_budget_nodes" {
  description = "Max percentage of nodes that can be disrupted simultaneously"
  type        = string
  default     = "10%"
}
