terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

locals {
  cluster_name     = "${var.project_name}-${var.client_name}"
  cluster_name_k8s = lower("${var.project_name}-${var.client_name}")

  common_tags = merge(
    var.tags,
    {
      Module = "Quantum-Workflows"
    }
  )
}

# Argo Workflows Controller IAM Role (IRSA)
resource "aws_iam_role" "argo_workflows" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  name = "${local.cluster_name}-argo-workflows-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:aud" = "sts.amazonaws.com"
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:${var.argo_namespace}:argo-workflow"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# S3 Bucket for Argo Workflows Artifacts
resource "aws_s3_bucket" "argo_artifacts" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  bucket        = "${local.cluster_name_k8s}-argo-artifacts"
  force_destroy = true # Allow bucket deletion even with objects during destroy

  tags = local.common_tags

  lifecycle {
    ignore_changes = [bucket] # Ignore if bucket already exists
  }
}

resource "aws_s3_bucket_versioning" "argo_artifacts" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  bucket = aws_s3_bucket.argo_artifacts[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "argo_artifacts" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  bucket = aws_s3_bucket.argo_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "argo_artifacts" {
  count = var.enable_s3_artifact_repository && var.artifact_retention_days > 0 ? 1 : 0

  bucket = aws_s3_bucket.argo_artifacts[0].id

  rule {
    id     = "artifact-cleanup"
    status = "Enabled"

    expiration {
      days = var.artifact_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.artifact_retention_days
    }
  }
}

resource "aws_s3_bucket_public_access_block" "argo_artifacts" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  bucket = aws_s3_bucket.argo_artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM Policy for Argo Workflows S3 Access
resource "aws_iam_policy" "argo_workflows_s3" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  name        = "${local.cluster_name}-argo-workflows-s3-policy"
  description = "IAM policy for Argo Workflows S3 artifact repository"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.argo_artifacts[0].arn,
          "${aws_s3_bucket.argo_artifacts[0].arn}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "argo_workflows_s3" {
  count = var.enable_s3_artifact_repository ? 1 : 0

  policy_arn = aws_iam_policy.argo_workflows_s3[0].arn
  role       = aws_iam_role.argo_workflows[0].name
}

# Argo Workflows Helm Release
resource "helm_release" "argo_workflows" {
  count = var.deploy_argo_workflows ? 1 : 0

  name       = "argo-workflows"
  namespace  = var.argo_namespace
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-workflows"
  version    = var.argo_workflows_version

  create_namespace = true
  timeout          = 600
  wait             = true
  wait_for_jobs    = false
  atomic           = false
  cleanup_on_fail  = true
  force_update     = true
  replace          = true
  disable_webhooks = true

  # Lifecycle settings for cleaner destroy
  lifecycle {
    create_before_destroy = false
  }

  # Server Configuration
  set {
    name  = "server.enabled"
    value = var.enable_argo_server
  }

  set {
    name  = "server.serviceType"
    value = var.server_service_type
  }

  # AWS Load Balancer annotations for internet-facing NLB
  set {
    name  = "server.serviceAnnotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  set {
    name  = "server.serviceAnnotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  set {
    name  = "server.replicas"
    value = var.server_replicas
  }

  # Controller Configuration
  set {
    name  = "controller.replicas"
    value = var.controller_replicas
  }

  set {
    name  = "controller.metricsConfig.enabled"
    value = var.enable_metrics
  }

  set {
    name  = "controller.workflowDefaults.spec.serviceAccountName"
    value = "argo-workflow"
  }

  # Executor Configuration
  set {
    name  = "executor.image.repository"
    value = "argoproj/argoexec"
  }

  # Schedule Argo components on managed nodes, not Karpenter nodes
  set {
    name  = "controller.nodeSelector.eks\\.amazonaws\\.com/nodegroup"
    value = var.nodegroup_name
  }

  set {
    name  = "server.nodeSelector.eks\\.amazonaws\\.com/nodegroup"
    value = var.nodegroup_name
  }

  # S3 Artifact Repository Configuration - disable default artifact repo in helm
  # We'll configure it via ConfigMap or workflow defaults
  # Also add Karpenter do-not-disrupt annotation to prevent node consolidation during workflow execution
  values = concat(
    # S3 artifact repository config
    var.enable_s3_artifact_repository ? [
      yamlencode({
        # Don't use helm's artifactRepository config due to template issues
        # Instead, use controller.workflowDefaults
        controller = {
          workflowDefaults = {
            spec = {
              serviceAccountName = "argo-workflow"
              # Add Karpenter do-not-disrupt annotation to prevent node termination during workflow execution
              podMetadata = var.protect_workflow_pods_from_disruption ? {
                annotations = {
                  "karpenter.sh/do-not-disrupt" = "true"
                }
              } : {}
            }
          }
        }
      })
    ] : [],
    # Karpenter protection without S3 artifact repository
    !var.enable_s3_artifact_repository && var.protect_workflow_pods_from_disruption ? [
      yamlencode({
        controller = {
          workflowDefaults = {
            spec = {
              podMetadata = {
                annotations = {
                  "karpenter.sh/do-not-disrupt" = "true"
                }
              }
            }
          }
        }
      })
    ] : [],
    # Custom helm values
    var.helm_values != null ? [var.helm_values] : []
  )

  # Workflow Archive (if PostgreSQL is configured)
  dynamic "set" {
    for_each = var.enable_workflow_archive ? [1] : []
    content {
      name  = "controller.persistence.archive"
      value = true
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.argo_workflows_s3
  ]
}

# Kubernetes Service Account for Argo Workflows with IRSA (for workflow execution)
resource "kubernetes_service_account" "argo_workflow" {
  count = var.deploy_argo_workflows && var.enable_s3_artifact_repository ? 1 : 0

  metadata {
    name      = "argo-workflow"
    namespace = var.argo_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.argo_workflows[0].arn
    }
  }

  depends_on = [helm_release.argo_workflows]
}

# ConfigMap to configure S3 artifact repository for IRSA
resource "kubernetes_config_map" "argo_artifact_repo" {
  count = var.deploy_argo_workflows && var.enable_s3_artifact_repository ? 1 : 0

  metadata {
    name      = "artifact-repositories"
    namespace = var.argo_namespace
    labels = {
      "workflows.argoproj.io/default-artifact-repository" = "default-artifact-repository"
    }
  }

  data = {
    "default-artifact-repository" = yamlencode({
      s3 = {
        bucket      = aws_s3_bucket.argo_artifacts[0].id
        region      = var.region
        endpoint    = "s3.amazonaws.com"
        useSDKCreds = true
      }
      archiveLogs = true
    })
  }

  depends_on = [helm_release.argo_workflows]
}

# ============================================
# Argo Admin ServiceAccount with Full Access
# ============================================

# Admin ServiceAccount for Argo UI and API access
resource "kubernetes_service_account" "argo_admin" {
  count = var.deploy_argo_workflows && var.create_admin_service_account ? 1 : 0

  metadata {
    name      = "${local.cluster_name_k8s}-argo-admin"
    namespace = var.argo_namespace
    labels = {
      "app.kubernetes.io/name"       = "argo-admin"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [helm_release.argo_workflows]
}

# Secret for Admin ServiceAccount Token (Kubernetes 1.24+)
resource "kubernetes_secret" "argo_admin_token" {
  count = var.deploy_argo_workflows && var.create_admin_service_account ? 1 : 0

  metadata {
    name      = "${local.cluster_name_k8s}-argo-admin-token"
    namespace = var.argo_namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.argo_admin[0].metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account.argo_admin]
}

# ClusterRole for Argo Admin - Full access to all Argo resources
resource "kubernetes_cluster_role" "argo_admin" {
  count = var.deploy_argo_workflows && var.create_admin_service_account ? 1 : 0

  metadata {
    name = "${local.cluster_name_k8s}-argo-admin"
    labels = {
      "app.kubernetes.io/name"       = "argo-admin"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # Workflows - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflows", "workflows/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Workflow Templates - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtemplates", "workflowtemplates/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Cluster Workflow Templates - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["clusterworkflowtemplates", "clusterworkflowtemplates/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # CronWorkflows - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["cronworkflows", "cronworkflows/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Workflow Event Bindings - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workfloweventbindings", "workfloweventbindings/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Workflow Artifact GC Tasks - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowartifactgctasks", "workflowartifactgctasks/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Workflow Task Results - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtaskresults", "workflowtaskresults/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Workflow Task Sets - full access
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtasksets", "workflowtasksets/finalizers"]
    verbs      = ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"]
  }

  # Pods - needed for viewing workflow pods
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  # Events - needed for viewing workflow events
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }

  # Secrets - needed for accessing workflow secrets
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }

  # ConfigMaps - needed for accessing workflow configmaps
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "watch"]
  }

  # ServiceAccounts - needed for viewing service accounts
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [helm_release.argo_workflows]
}

# ClusterRoleBinding for Argo Admin
resource "kubernetes_cluster_role_binding" "argo_admin" {
  count = var.deploy_argo_workflows && var.create_admin_service_account ? 1 : 0

  metadata {
    name = "${local.cluster_name_k8s}-argo-admin"
    labels = {
      "app.kubernetes.io/name"       = "argo-admin"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argo_admin[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argo_admin[0].metadata[0].name
    namespace = var.argo_namespace
  }

  depends_on = [
    kubernetes_service_account.argo_admin,
    kubernetes_cluster_role.argo_admin
  ]
}

# Store Argo Admin Token in AWS Secrets Manager
resource "aws_secretsmanager_secret" "argo_admin_token" {
  count = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? 1 : 0

  name        = "${local.cluster_name}/argo/admin-token"
  description = "Argo Workflows Admin ServiceAccount token for ${local.cluster_name}"

  # Set to 0 for immediate deletion on destroy (no recovery period)
  recovery_window_in_days = 0

  tags = merge(
    local.common_tags,
    {
      Purpose = "ArgoWorkflowsAdminToken"
    }
  )
}

resource "aws_secretsmanager_secret_version" "argo_admin_token" {
  count = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? 1 : 0

  secret_id = aws_secretsmanager_secret.argo_admin_token[0].id

  secret_string = jsonencode({
    service_account_name     = kubernetes_service_account.argo_admin[0].metadata[0].name
    namespace                = var.argo_namespace
    token                    = kubernetes_secret.argo_admin_token[0].data["token"]
    cluster_name             = local.cluster_name
    argo_server_internal_url = "http://argo-workflows-server.${var.argo_namespace}.svc.cluster.local:2746"
    usage_instructions       = "Use this token in the Authorization header: Bearer <token>"
  })

  depends_on = [kubernetes_secret.argo_admin_token]
}

# Data source to get the LoadBalancer hostname after service is created
data "kubernetes_service" "argo_server" {
  count = var.deploy_argo_workflows && var.server_service_type == "LoadBalancer" ? 1 : 0

  metadata {
    name      = "argo-workflows-server"
    namespace = var.argo_namespace
  }

  depends_on = [helm_release.argo_workflows]
}

# Store Argo API URL configuration in AWS Secrets Manager
resource "aws_secretsmanager_secret" "argo_api_url" {
  count = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? 1 : 0

  name        = "${local.cluster_name}/argo/api-url"
  description = "Argo Workflows API URL and configuration for ${local.cluster_name}"

  # Set to 0 for immediate deletion on destroy (no recovery period)
  recovery_window_in_days = 0

  tags = merge(
    local.common_tags,
    {
      Purpose = "ArgoWorkflowsAPIConfig"
    }
  )
}

resource "aws_secretsmanager_secret_version" "argo_api_url" {
  count = var.deploy_argo_workflows && var.create_admin_service_account && var.store_token_in_secrets_manager ? 1 : 0

  secret_id = aws_secretsmanager_secret.argo_api_url[0].id

  secret_string = jsonencode({
    argo_server_url      = var.server_service_type == "LoadBalancer" ? "http://${data.kubernetes_service.argo_server[0].status[0].load_balancer[0].ingress[0].hostname}:2746" : "http://argo-workflows-server.${var.argo_namespace}.svc.cluster.local:2746"
    cluster_name         = local.cluster_name
    namespace            = var.argo_namespace
    service_account_name = kubernetes_service_account.argo_admin[0].metadata[0].name
  })

  depends_on = [data.kubernetes_service.argo_server, kubernetes_service_account.argo_admin]
}

# =============================================================================
# Cleanup Script for Argo Workflows IAM Resources
# =============================================================================
# This ensures all IAM roles and policies created for Argo Workflows are cleaned up on destroy

resource "null_resource" "cleanup_argo_iam_resources" {
  triggers = {
    cluster_name = local.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      CLUSTER_NAME="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      
      echo "=== Cleaning up Argo Workflows IAM resources for cluster: $CLUSTER_NAME ==="
      
      # Function to detach all policies from a role and delete the role
      cleanup_role() {
        local role_name=$1
        echo "Processing role: $role_name"
        
        # Check if role exists
        if ! aws iam get-role --role-name "$role_name" --region "$REGION" 2>/dev/null; then
          echo "Role $role_name does not exist, skipping..."
          return 0
        fi
        
        # Detach all managed policies
        echo "Detaching managed policies from $role_name..."
        attached_policies=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[*].PolicyArn' --output text --region "$REGION" 2>/dev/null || echo "")
        for policy_arn in $attached_policies; do
          if [ -n "$policy_arn" ] && [ "$policy_arn" != "None" ]; then
            echo "Detaching policy: $policy_arn"
            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --region "$REGION" 2>/dev/null || true
          fi
        done
        
        # Delete inline policies
        echo "Deleting inline policies from $role_name..."
        inline_policies=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[*]' --output text --region "$REGION" 2>/dev/null || echo "")
        for policy_name in $inline_policies; do
          if [ -n "$policy_name" ] && [ "$policy_name" != "None" ]; then
            echo "Deleting inline policy: $policy_name"
            aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name" --region "$REGION" 2>/dev/null || true
          fi
        done
        
        # Delete the role
        echo "Deleting role: $role_name"
        aws iam delete-role --role-name "$role_name" --region "$REGION" 2>/dev/null || true
      }
      
      # Function to delete a customer managed policy
      cleanup_policy() {
        local policy_name=$1
        local account_id=$(aws sts get-caller-identity --query Account --output text)
        local policy_arn="arn:aws:iam::$account_id:policy/$policy_name"
        
        echo "Processing policy: $policy_name"
        
        # Check if policy exists
        if ! aws iam get-policy --policy-arn "$policy_arn" --region "$REGION" 2>/dev/null; then
          echo "Policy $policy_name does not exist, skipping..."
          return 0
        fi
        
        # Detach from all entities
        echo "Detaching policy from all entities..."
        
        # Detach from roles
        attached_roles=$(aws iam list-entities-for-policy --policy-arn "$policy_arn" --query 'PolicyRoles[*].RoleName' --output text --region "$REGION" 2>/dev/null || echo "")
        for role_name in $attached_roles; do
          if [ -n "$role_name" ] && [ "$role_name" != "None" ]; then
            echo "Detaching from role: $role_name"
            aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" --region "$REGION" 2>/dev/null || true
          fi
        done
        
        # Delete all non-default policy versions
        versions=$(aws iam list-policy-versions --policy-arn "$policy_arn" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text --region "$REGION" 2>/dev/null || echo "")
        for version in $versions; do
          if [ -n "$version" ] && [ "$version" != "None" ]; then
            echo "Deleting policy version: $version"
            aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version" --region "$REGION" 2>/dev/null || true
          fi
        done
        
        # Delete the policy
        echo "Deleting policy: $policy_name"
        aws iam delete-policy --policy-arn "$policy_arn" --region "$REGION" 2>/dev/null || true
      }
      
      # Cleanup Argo Workflows role and policy
      cleanup_role "$CLUSTER_NAME-argo-workflows-role"
      cleanup_policy "$CLUSTER_NAME-argo-workflows-s3-policy"
      
      echo "=== Argo Workflows IAM resources cleanup completed ==="
    EOT
  }
}

# =============================================================================
# Cleanup Cross-Account S3 Bucket Access on Destroy
# =============================================================================
# Removes the cross-account access statement from quantum-machin-mode-config bucket

resource "null_resource" "cleanup_cross_account_s3_access" {
  triggers = {
    region     = var.region
    account_id = data.aws_caller_identity.current.account_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      BUCKET_NAME="quantum-machin-mode-config"
      ACCOUNT_ID="${self.triggers.account_id}"
      STATEMENT_SID="AllowCrossAccountAccess$ACCOUNT_ID"
      
      echo "=== Removing cross-account S3 access for account: $ACCOUNT_ID from bucket: $BUCKET_NAME ==="
      
      # Get current bucket policy
      CURRENT_POLICY=$(aws s3api get-bucket-policy --bucket "$BUCKET_NAME" --query Policy --output text 2>/dev/null || echo "")
      
      if [ -z "$CURRENT_POLICY" ] || [ "$CURRENT_POLICY" == "None" ]; then
        echo "No bucket policy found, nothing to clean up"
        exit 0
      fi
      
      echo "Current policy retrieved, removing cross-account statement..."
      
      # Use jq to remove the cross-account statement for this account
      # Filter out the statement with matching Sid
      NEW_POLICY=$(echo "$CURRENT_POLICY" | jq --arg sid "$STATEMENT_SID" '
        .Statement = [.Statement[] | select(.Sid != $sid)]
      ')
      
      # Check if any statements remain
      STATEMENT_COUNT=$(echo "$NEW_POLICY" | jq '.Statement | length')
      
      if [ "$STATEMENT_COUNT" -eq 0 ]; then
        echo "No statements remaining, deleting bucket policy entirely"
        aws s3api delete-bucket-policy --bucket "$BUCKET_NAME" 2>/dev/null || true
      else
        echo "Updating bucket policy with $STATEMENT_COUNT remaining statements"
        echo "$NEW_POLICY" > /tmp/updated-bucket-policy.json
        aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy file:///tmp/updated-bucket-policy.json 2>/dev/null || true
        rm -f /tmp/updated-bucket-policy.json
      fi
      
      echo "=== Cross-account S3 access cleanup completed ==="
    EOT
  }
}

