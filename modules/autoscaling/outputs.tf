output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_controller_role_name" {
  description = "Name of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller.name
}

output "karpenter_interruption_queue_arn" {
  description = "ARN of the SQS queue for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.arn
}

output "karpenter_interruption_queue_name" {
  description = "Name of the SQS queue for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_interruption_queue_url" {
  description = "URL of the SQS queue for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "helm_release_name" {
  description = "Name of the Karpenter Helm release"
  value       = var.deploy_karpenter ? helm_release.karpenter[0].name : null
}

output "helm_release_namespace" {
  description = "Namespace of the Karpenter Helm release"
  value       = var.deploy_karpenter ? helm_release.karpenter[0].namespace : null
}

output "helm_release_version" {
  description = "Version of the Karpenter Helm release"
  value       = var.deploy_karpenter ? helm_release.karpenter[0].version : null
}

# NodePool and EC2NodeClass Outputs
output "nodepool_name" {
  description = "Name of the default NodePool"
  value       = var.deploy_karpenter && var.create_default_nodepool ? "default" : null
}

output "ec2nodeclass_name" {
  description = "Name of the default EC2NodeClass"
  value       = var.deploy_karpenter && var.create_default_nodepool ? "default" : null
}

output "nodepool_cpu_limit" {
  description = "CPU limit for the NodePool"
  value       = var.nodepool_cpu_limit
}

output "nodepool_memory_limit" {
  description = "Memory limit for the NodePool"
  value       = var.nodepool_memory_limit
}

output "capacity_types" {
  description = "Allowed capacity types for the NodePool"
  value       = var.capacity_types
}

output "instance_categories" {
  description = "Allowed instance categories for the NodePool"
  value       = var.instance_categories
}
