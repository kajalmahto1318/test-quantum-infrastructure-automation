output "secret_arns" {
  description = "ARNs of created Secrets Manager secrets"
  value       = { for k, v in aws_secretsmanager_secret.main : k => v.arn }
}

output "secret_ids" {
  description = "IDs of created Secrets Manager secrets"
  value       = { for k, v in aws_secretsmanager_secret.main : k => v.id }
}

output "secret_names" {
  description = "Names of created Secrets Manager secrets"
  value       = { for k, v in aws_secretsmanager_secret.main : k => v.name }
}

output "ssm_parameter_arns" {
  description = "ARNs of created SSM parameters"
  value       = { for k, v in aws_ssm_parameter.main : k => v.arn }
}

output "ssm_parameter_names" {
  description = "Names of created SSM parameters"
  value       = { for k, v in aws_ssm_parameter.main : k => v.name }
}

output "external_secrets_role_arn" {
  description = "ARN of the External Secrets Operator IAM role"
  value       = var.deploy_external_secrets_operator ? aws_iam_role.external_secrets[0].arn : null
}

output "external_secrets_role_name" {
  description = "Name of the External Secrets Operator IAM role"
  value       = var.deploy_external_secrets_operator ? aws_iam_role.external_secrets[0].name : null
}

output "external_secrets_namespace" {
  description = "Namespace where External Secrets Operator is deployed"
  value       = var.deploy_external_secrets_operator ? helm_release.external_secrets[0].namespace : null
}

output "external_secrets_release_name" {
  description = "Name of the External Secrets Operator Helm release"
  value       = var.deploy_external_secrets_operator ? helm_release.external_secrets[0].name : null
}

output "external_secrets_version" {
  description = "Version of the External Secrets Operator Helm release"
  value       = var.deploy_external_secrets_operator ? helm_release.external_secrets[0].version : null
}

output "cluster_secret_store_name" {
  description = "Name of the ClusterSecretStore for AWS Secrets Manager"
  value       = var.deploy_external_secrets_operator && var.create_cluster_secret_store ? lower("${var.project_name}-${var.client_name}-aws-secrets") : null
}

output "cluster_secret_store_ssm_name" {
  description = "Name of the ClusterSecretStore for AWS Parameter Store"
  value       = var.deploy_external_secrets_operator && var.create_cluster_secret_store && var.enable_ssm_provider ? lower("${var.project_name}-${var.client_name}-aws-ssm") : null
}

output "csi_driver_release_name" {
  description = "Name of the Secrets Store CSI Driver Helm release"
  value       = var.deploy_secrets_store_csi_driver ? helm_release.secrets_store_csi_driver[0].name : null
}
