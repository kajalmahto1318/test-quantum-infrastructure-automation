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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}

locals {
  cluster_name     = "${var.project_name}-${var.client_name}"
  cluster_name_k8s = lower("${var.project_name}-${var.client_name}")

  common_tags = merge(
    var.tags,
    {
      Module = "SecretsManager"
    }
  )
}

# Secrets Manager Secrets
resource "aws_secretsmanager_secret" "main" {
  for_each = var.secrets

  name        = "${local.cluster_name}/${each.key}"
  description = lookup(each.value, "description", "Managed by Terraform for ${local.cluster_name}")

  kms_key_id                     = var.kms_key_id
  recovery_window_in_days        = var.recovery_window_in_days
  force_overwrite_replica_secret = var.force_overwrite_replica_secret

  dynamic "replica" {
    for_each = var.replica_regions
    content {
      region     = replica.value.region
      kms_key_id = lookup(replica.value, "kms_key_id", null)
    }
  }

  tags = merge(
    local.common_tags,
    {
      SecretName = each.key
    }
  )
}

resource "aws_secretsmanager_secret_version" "main" {
  for_each = { for k, v in var.secrets : k => v if lookup(v, "secret_string", null) != null }

  secret_id     = aws_secretsmanager_secret.main[each.key].id
  secret_string = each.value.secret_string
}

# IAM Role for External Secrets Operator (IRSA)
resource "aws_iam_role" "external_secrets" {
  count = var.deploy_external_secrets_operator ? 1 : 0

  name = "${local.cluster_name}-external-secrets-role"

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
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:${var.external_secrets_namespace}:external-secrets"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "external_secrets" {
  count = var.deploy_external_secrets_operator ? 1 : 0

  name        = "${local.cluster_name}-external-secrets-policy"
  description = "IAM policy for External Secrets Operator"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = var.secrets_access_pattern != null ? var.secrets_access_pattern : "arn:aws:secretsmanager:${var.region}:*:secret:${local.cluster_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = var.ssm_access_pattern != null ? var.ssm_access_pattern : "arn:aws:ssm:${var.region}:*:parameter/${local.cluster_name}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_id != null ? var.kms_key_id : "*"
        Condition = var.kms_key_id == null ? {
          StringLike = {
            "kms:ViaService" = [
              "secretsmanager.${var.region}.amazonaws.com",
              "ssm.${var.region}.amazonaws.com"
            ]
          }
        } : null
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  count = var.deploy_external_secrets_operator ? 1 : 0

  policy_arn = aws_iam_policy.external_secrets[0].arn
  role       = aws_iam_role.external_secrets[0].name
}

# External Secrets Operator Helm Release
resource "helm_release" "external_secrets" {
  count = var.deploy_external_secrets_operator ? 1 : 0

  name       = "external-secrets"
  namespace  = var.external_secrets_namespace
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.external_secrets_version

  create_namespace = true

  set {
    name  = "serviceAccount.create"
    value = true
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets[0].arn
  }

  set {
    name  = "installCRDs"
    value = true
  }

  set {
    name  = "webhook.port"
    value = 9443
  }

  set {
    name  = "certController.requeueInterval"
    value = "5m"
  }

  values = var.helm_values != null ? [var.helm_values] : []

  depends_on = [
    aws_iam_role_policy_attachment.external_secrets
  ]
}

# ClusterSecretStore for AWS Secrets Manager
resource "kubectl_manifest" "cluster_secret_store" {
  count = var.deploy_external_secrets_operator && var.create_cluster_secret_store ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "${local.cluster_name_k8s}-aws-secrets"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = var.external_secrets_namespace
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}

# ClusterSecretStore for AWS Parameter Store
resource "kubectl_manifest" "cluster_secret_store_ssm" {
  count = var.deploy_external_secrets_operator && var.create_cluster_secret_store && var.enable_ssm_provider ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "${local.cluster_name_k8s}-aws-ssm"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = var.external_secrets_namespace
              }
            }
          }
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets]
}

# SSM Parameters (optional)
resource "aws_ssm_parameter" "main" {
  for_each = var.ssm_parameters

  name        = "/${local.cluster_name}/${each.key}"
  description = lookup(each.value, "description", "Managed by Terraform for ${local.cluster_name}")
  type        = lookup(each.value, "type", "SecureString")
  value       = each.value.value
  key_id      = lookup(each.value, "type", "SecureString") == "SecureString" ? var.kms_key_id : null
  tier        = lookup(each.value, "tier", "Standard")

  tags = merge(
    local.common_tags,
    {
      ParameterName = each.key
    }
  )
}

# Secrets Store CSI Driver (alternative to External Secrets Operator)
resource "helm_release" "secrets_store_csi_driver" {
  count = var.deploy_secrets_store_csi_driver ? 1 : 0

  name       = "secrets-store-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.secrets_store_csi_driver_version

  set {
    name  = "syncSecret.enabled"
    value = true
  }

  set {
    name  = "enableSecretRotation"
    value = var.enable_secret_rotation
  }

  set {
    name  = "rotationPollInterval"
    value = var.rotation_poll_interval
  }
}

# AWS Secrets Store CSI Driver Provider
resource "helm_release" "aws_secrets_provider" {
  count = var.deploy_secrets_store_csi_driver ? 1 : 0

  name       = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.aws_secrets_provider_version

  depends_on = [helm_release.secrets_store_csi_driver]
}
