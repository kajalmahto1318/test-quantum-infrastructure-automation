variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "client_name" {
  description = "Name of the client"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be created"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "List of subnet IDs for the EKS node group (usually private subnets)"
  type        = list(string)
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "endpoint_public_access" {
  description = "Enable public access to the cluster API endpoint"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Enable private access to the cluster API endpoint"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "List of CIDR blocks that can access the public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = "List of log types to enable for the cluster"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

# Node Group Configuration
variable "instance_types" {
  description = "List of instance types for the node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "capacity_type" {
  description = "Type of capacity associated with the EKS Node Group (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "disk_size" {
  description = "Disk size in GiB for worker nodes"
  type        = number
  default     = 50
}

variable "desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}

variable "node_labels" {
  description = "Labels to apply to nodes"
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Taints to apply to nodes"
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

# Addon Configuration
variable "enable_vpc_cni_addon" {
  description = "Enable VPC CNI addon"
  type        = bool
  default     = true
}

variable "enable_coredns_addon" {
  description = "Enable CoreDNS addon"
  type        = bool
  default     = true
}

variable "enable_kube_proxy_addon" {
  description = "Enable kube-proxy addon"
  type        = bool
  default     = true
}

variable "enable_ebs_csi_addon" {
  description = "Enable EBS CSI Driver addon"
  type        = bool
  default     = true
}

# Kubeconfig and Secrets Manager
variable "region" {
  description = "AWS region for kubeconfig"
  type        = string
}

variable "store_kubeconfig_in_secrets_manager" {
  description = "Store kubeconfig in AWS Secrets Manager"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# EKS Access Entries Configuration
# =============================================================================

variable "enable_cluster_creator_admin_permissions" {
  description = "Enable admin permissions for cluster creator"
  type        = bool
  default     = true
}

variable "access_entries" {
  description = "Map of access entries for the EKS cluster"
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD") # STANDARD, FARGATE_LINUX, EC2_LINUX, EC2_WINDOWS
    user_name         = optional(string)
    kubernetes_groups = optional(list(string), [])
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string # cluster or namespace
        namespaces = optional(list(string), [])
      })
    })), {})
  }))
  default = {}
}

variable "enable_root_account_access" {
  description = "Enable root account access to the cluster with admin policy"
  type        = bool
  default     = true
}

variable "enable_karpenter_node_access" {
  description = "Enable access entry for Karpenter nodes"
  type        = bool
  default     = true
}

variable "karpenter_node_role_name" {
  description = "Name of the Karpenter node IAM role (will be created by Karpenter module)"
  type        = string
  default     = ""
}
