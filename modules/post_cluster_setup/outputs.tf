# =============================================================================
# CLUSTER READINESS OUTPUTS
# =============================================================================

output "cluster_readiness_verified" {
  description = "Whether cluster readiness was verified"
  value       = var.verify_cluster_readiness
}

output "karpenter_readiness_verified" {
  description = "Whether Karpenter readiness was verified"
  value       = var.verify_cluster_readiness && var.wait_for_karpenter
}

# =============================================================================
# NAMESPACE OUTPUTS
# =============================================================================

output "namespaces_created" {
  description = "List of namespaces created"
  value       = var.deploy_namespaces ? var.namespaces : []
}

output "namespace_details" {
  description = "Details of created namespaces"
  value = {
    for ns in kubernetes_namespace.namespaces : ns.metadata[0].name => {
      name   = ns.metadata[0].name
      labels = ns.metadata[0].labels
      uid    = ns.metadata[0].uid
    }
  }
}

# =============================================================================
# RBAC OUTPUTS
# =============================================================================

output "admin_role_name" {
  description = "Name of the cluster admin role"
  value       = var.create_admin_role ? kubernetes_cluster_role.admin[0].metadata[0].name : null
}

output "developer_role_name" {
  description = "Name of the developer role"
  value       = var.create_developer_role ? kubernetes_cluster_role.developer[0].metadata[0].name : null
}

output "readonly_role_name" {
  description = "Name of the read-only role"
  value       = var.create_readonly_role ? kubernetes_cluster_role.readonly[0].metadata[0].name : null
}

# =============================================================================
# INGRESS CONTROLLER OUTPUTS
# =============================================================================

output "ingress_controller_deployed" {
  description = "Whether an ingress controller was deployed"
  value       = var.deploy_ingress_controller
}

output "ingress_controller_type" {
  description = "Type of ingress controller deployed"
  value       = var.deploy_ingress_controller ? var.ingress_controller_type : null
}

output "ingress_controller_namespace" {
  description = "Namespace where ingress controller is deployed"
  value       = var.deploy_ingress_controller ? var.ingress_controller_namespace : null
}

output "nginx_ingress_release_name" {
  description = "Name of the NGINX ingress Helm release"
  value       = var.deploy_ingress_controller && var.ingress_controller_type == "nginx" ? helm_release.nginx_ingress[0].name : null
}

output "nginx_ingress_version" {
  description = "Version of the NGINX ingress Helm release"
  value       = var.deploy_ingress_controller && var.ingress_controller_type == "nginx" ? helm_release.nginx_ingress[0].version : null
}

output "alb_controller_release_name" {
  description = "Name of the ALB controller Helm release"
  value       = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? helm_release.alb_controller[0].name : null
}

output "alb_controller_role_arn" {
  description = "ARN of the ALB controller IAM role"
  value       = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? aws_iam_role.alb_controller[0].arn : null
}

# =============================================================================
# RESOURCE MANAGEMENT OUTPUTS
# =============================================================================

output "resource_quotas_deployed" {
  description = "Whether resource quotas were deployed"
  value       = var.deploy_resource_quotas
}

output "resource_quotas_namespaces" {
  description = "Namespaces with resource quotas"
  value       = var.deploy_resource_quotas ? keys(var.resource_quotas) : []
}

output "limit_ranges_deployed" {
  description = "Whether limit ranges were deployed"
  value       = var.deploy_limit_ranges
}

output "limit_ranges_namespaces" {
  description = "Namespaces with limit ranges"
  value       = var.deploy_limit_ranges ? keys(var.limit_ranges) : []
}

output "network_policies_deployed" {
  description = "Whether network policies were deployed"
  value       = var.deploy_network_policies
}

output "pod_security_standards_enforced" {
  description = "Whether Pod Security Standards were enforced"
  value       = var.enforce_pod_security_standards
}

output "pod_security_level" {
  description = "Pod Security Standard level applied"
  value       = var.enforce_pod_security_standards ? var.pod_security_level : null
}

# =============================================================================
# NODECLAIM CLEANER OUTPUTS
# =============================================================================

output "nodeclaim_cleaner_enabled" {
  description = "Whether the NodeClaim cleaner is deployed"
  value       = var.enable_nodeclaim_cleaner && var.enable_karpenter
}

output "nodeclaim_cleaner_deployment_name" {
  description = "Name of the NodeClaim cleaner deployment"
  value       = var.enable_nodeclaim_cleaner && var.enable_karpenter ? kubernetes_deployment_v1.nodeclaim_cleaner[0].metadata[0].name : null
}

output "nodeclaim_cleaner_service_account" {
  description = "Service account used by NodeClaim cleaner"
  value       = var.enable_nodeclaim_cleaner && var.enable_karpenter ? kubernetes_service_account_v1.nodeclaim_cleaner[0].metadata[0].name : null
}

# =============================================================================
# KARPENTER MANIFESTS OUTPUTS
# =============================================================================

output "karpenter_ec2_nodeclass_created" {
  description = "Whether Karpenter EC2NodeClass was created"
  value       = var.create_karpenter_manifests
}

output "karpenter_ec2_nodeclass_name" {
  description = "Name of the created EC2NodeClass"
  value       = var.create_karpenter_manifests ? var.karpenter_nodeclass_name : null
}

output "karpenter_nodepool_created" {
  description = "Whether Karpenter NodePool was created"
  value       = var.create_karpenter_manifests
}

output "karpenter_nodepool_name" {
  description = "Name of the created NodePool"
  value       = var.create_karpenter_manifests ? var.karpenter_nodepool_name : null
}