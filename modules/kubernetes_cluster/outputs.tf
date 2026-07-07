output "cluster_id" {
  description = "The ID of the EKS cluster"
  value       = aws_eks_cluster.main.id
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_version" {
  description = "The Kubernetes version for the cluster"
  value       = aws_eks_cluster.main.version
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.eks_cluster.id
}

output "eks_cluster_security_group_id" {
  description = "The cluster security group that was created by Amazon EKS for the cluster"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS nodes"
  value       = aws_security_group.eks_nodes.id
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the EKS cluster"
  value       = aws_iam_role.eks_cluster.arn
}

output "node_group_iam_role_arn" {
  description = "IAM role ARN of the EKS node group"
  value       = aws_iam_role.eks_node_group.arn
}

output "node_group_iam_role_name" {
  description = "IAM role name of the EKS node group"
  value       = aws_iam_role.eks_node_group.name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "node_group_id" {
  description = "EKS Cluster name and EKS Node Group name separated by a colon"
  value       = aws_eks_node_group.main.id
}

output "node_group_arn" {
  description = "ARN of the EKS Node Group"
  value       = aws_eks_node_group.main.arn
}

output "node_group_status" {
  description = "Status of the EKS Node Group"
  value       = aws_eks_node_group.main.status
}

output "node_group_name" {
  description = "Name of the EKS Node Group"
  value       = aws_eks_node_group.main.node_group_name
}

output "launch_template_id" {
  description = "ID of the launch template for node group instances"
  value       = aws_launch_template.eks_nodes.id
}

output "launch_template_name" {
  description = "Name of the launch template for node group instances"
  value       = aws_launch_template.eks_nodes.name
}

output "cluster_primary_security_group_id" {
  description = "The cluster primary security group ID created by the EKS cluster on its own"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# Kubeconfig Secrets Manager Outputs
output "kubeconfig_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret containing the kubeconfig"
  value       = var.store_kubeconfig_in_secrets_manager ? aws_secretsmanager_secret.kubeconfig[0].arn : null
}

output "kubeconfig_secret_name" {
  description = "Name of the AWS Secrets Manager secret containing the kubeconfig"
  value       = var.store_kubeconfig_in_secrets_manager ? aws_secretsmanager_secret.kubeconfig[0].name : null
}

# =============================================================================
# EKS Access Entries Outputs
# =============================================================================

output "access_entry_root_arn" {
  description = "Principal ARN for root account access entry"
  value       = var.enable_root_account_access ? aws_eks_access_entry.root_account[0].principal_arn : null
}

output "access_entry_node_group_arn" {
  description = "Principal ARN for node group access entry"
  value       = aws_eks_access_entry.node_group.principal_arn
}

output "access_entry_karpenter_arn" {
  description = "Principal ARN for Karpenter nodes access entry"
  value       = var.enable_karpenter_node_access && var.karpenter_node_role_name != "" ? aws_eks_access_entry.karpenter_nodes[0].principal_arn : null
}

output "access_entries_custom" {
  description = "Map of custom access entry ARNs"
  value       = { for k, v in aws_eks_access_entry.custom : k => v.principal_arn }
}
