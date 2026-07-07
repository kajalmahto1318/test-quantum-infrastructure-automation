output "argo_workflows_role_arn" {
  description = "ARN of the Argo Workflows IAM role"
  value       = var.enable_s3_artifact_repository ? aws_iam_role.argo_workflows[0].arn : null
}

output "argo_artifacts_bucket_name" {
  description = "Name of the S3 bucket for Argo Workflows artifacts"
  value       = var.enable_s3_artifact_repository ? aws_s3_bucket.argo_artifacts[0].id : null
}

output "argo_artifacts_bucket_arn" {
  description = "ARN of the S3 bucket for Argo Workflows artifacts"
  value       = var.enable_s3_artifact_repository ? aws_s3_bucket.argo_artifacts[0].arn : null
}

output "argo_workflows_namespace" {
  description = "Namespace where Argo Workflows is deployed"
  value       = var.deploy_argo_workflows ? helm_release.argo_workflows[0].namespace : null
}

output "argo_workflows_release_name" {
  description = "Name of the Argo Workflows Helm release"
  value       = var.deploy_argo_workflows ? helm_release.argo_workflows[0].name : null
}

output "argo_workflows_version" {
  description = "Version of the Argo Workflows Helm release"
  value       = var.deploy_argo_workflows ? helm_release.argo_workflows[0].version : null
}

# Admin ServiceAccount Outputs
output "argo_admin_service_account_name" {
  description = "Name of the Argo admin ServiceAccount"
  value       = var.deploy_argo_workflows && var.create_admin_service_account ? kubernetes_service_account.argo_admin[0].metadata[0].name : null
}

output "argo_admin_token_secret_name" {
  description = "Name of the Kubernetes secret containing the admin token"
  value       = var.deploy_argo_workflows && var.create_admin_service_account ? kubernetes_secret.argo_admin_token[0].metadata[0].name : null
}

output "argo_admin_token_secrets_manager_arn" {
  description = "ARN of the AWS Secrets Manager secret containing the admin token"
  value       = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? aws_secretsmanager_secret.argo_admin_token[0].arn : null
}

output "argo_admin_token_secrets_manager_name" {
  description = "Name of the AWS Secrets Manager secret containing the admin token"
  value       = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? aws_secretsmanager_secret.argo_admin_token[0].name : null
}

# API URL Outputs
output "argo_api_url_secrets_manager_arn" {
  description = "ARN of the AWS Secrets Manager secret containing the Argo API URL config"
  value       = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? aws_secretsmanager_secret.argo_api_url[0].arn : null
}

output "argo_api_url_secrets_manager_name" {
  description = "Name of the AWS Secrets Manager secret containing the Argo API URL config"
  value       = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? aws_secretsmanager_secret.argo_api_url[0].name : null
}

output "argo_server_external_url" {
  description = "External URL for Argo Workflows server (if LoadBalancer)"
  value       = var.deploy_argo_workflows && var.server_service_type == "LoadBalancer" ? try("http://${data.kubernetes_service.argo_server[0].status[0].load_balancer[0].ingress[0].hostname}:2746", null) : null
}

output "argo_server_internal_url" {
  description = "Internal cluster URL for Argo Workflows server"
  value       = var.deploy_argo_workflows ? "http://argo-workflows-server.${var.argo_namespace}.svc.cluster.local:2746" : null
}
