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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

locals {
  cluster_name     = "${var.project_name}-${var.client_name}"
  cluster_name_k8s = lower("${var.project_name}-${var.client_name}")

  common_tags = merge(
    var.tags,
    {
      Module = "PostClusterSetup"
    }
  )
}

# =============================================================================
# CLUSTER READINESS CHECKS
# =============================================================================

# Wait for cluster to be fully ready before proceeding
resource "time_sleep" "wait_for_cluster" {
  create_duration = var.cluster_readiness_wait_time

  triggers = {
    cluster_endpoint = var.cluster_endpoint
  }
}

# Verify Kubernetes API is accessible
resource "null_resource" "verify_k8s_api" {
  count = var.verify_cluster_readiness ? 1 : 0

  triggers = {
    cluster_endpoint = var.cluster_endpoint
    always_run       = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Verifying Kubernetes API is accessible..."
      
      # Set up kubeconfig for cluster access
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --kubeconfig /tmp/kubeconfig-${var.cluster_name}
      export KUBECONFIG=/tmp/kubeconfig-${var.cluster_name}
      
      # Wait for API server to be ready
      MAX_RETRIES=30
      RETRY_COUNT=0
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if kubectl get nodes &>/dev/null; then
          echo "✅ Kubernetes API is accessible"
          break
        fi
        echo "Waiting for Kubernetes API... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT+1))
      done
      
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "❌ Failed to connect to Kubernetes API after $MAX_RETRIES attempts"
        exit 1
      fi
      
      # Verify nodes are ready
      echo "Waiting for at least one node to be Ready..."
      RETRY_COUNT=0
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
        if [ "$READY_NODES" -ge 1 ]; then
          echo "✅ Found $READY_NODES Ready node(s)"
          break
        fi
        echo "Waiting for nodes to be ready... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT+1))
      done
      
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "❌ No ready nodes found after $MAX_RETRIES attempts"
        exit 1
      fi
      
      rm -f /tmp/kubeconfig-${var.cluster_name}
      echo "✅ Cluster readiness verification complete"
    EOT

    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key
      AWS_SECRET_ACCESS_KEY = var.aws_secret_key
      AWS_DEFAULT_REGION    = var.region
    }
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Verify Karpenter is healthy (if enabled)
resource "null_resource" "verify_karpenter" {
  count = var.verify_cluster_readiness && var.wait_for_karpenter ? 1 : 0

  triggers = {
    cluster_endpoint = var.cluster_endpoint
    always_run       = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Verifying Karpenter is healthy..."
      
      # Set up kubeconfig
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --kubeconfig /tmp/kubeconfig-${var.cluster_name}
      export KUBECONFIG=/tmp/kubeconfig-${var.cluster_name}
      
      MAX_RETRIES=30
      RETRY_COUNT=0
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        # Check if Karpenter pods are running
        KARPENTER_READY=$(kubectl get pods -n ${var.karpenter_namespace} -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        
        if [ "$KARPENTER_READY" -ge 1 ]; then
          echo "✅ Karpenter is running with $KARPENTER_READY pod(s)"
          
          # Verify NodePool exists
          if kubectl get nodepools.karpenter.sh &>/dev/null; then
            NODEPOOL_COUNT=$(kubectl get nodepools.karpenter.sh --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [ "$NODEPOOL_COUNT" -ge 1 ]; then
              echo "✅ Found $NODEPOOL_COUNT NodePool(s)"
              break
            fi
          fi
        fi
        
        echo "Waiting for Karpenter to be ready... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 10
        RETRY_COUNT=$((RETRY_COUNT+1))
      done
      
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "⚠️  Karpenter readiness check timed out, continuing anyway..."
      fi
      
      rm -f /tmp/kubeconfig-${var.cluster_name}
      echo "✅ Karpenter verification complete"
    EOT

    environment = {
      AWS_ACCESS_KEY_ID     = var.aws_access_key
      AWS_SECRET_ACCESS_KEY = var.aws_secret_key
      AWS_DEFAULT_REGION    = var.region
    }
  }

  depends_on = [null_resource.verify_k8s_api]
}

# =============================================================================
# NAMESPACE CREATION
# =============================================================================

resource "kubernetes_namespace" "namespaces" {
  for_each = var.deploy_namespaces ? toset(var.namespaces) : toset([])

  metadata {
    name = each.value

    labels = merge(
      {
        "managed-by" = "terraform"
        "project"    = var.project_name
        "client"     = lower(var.client_name)
      },
      lookup(var.namespace_labels, each.value, {})
    )

    annotations = lookup(var.namespace_annotations, each.value, {})
  }

  lifecycle {
    # Ignore changes if namespace already exists (e.g., created by Helm charts)
    ignore_changes = [metadata]
  }

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter
  ]
}

# =============================================================================
# RBAC CONFIGURATION
# =============================================================================

# Cluster Admin Role
resource "kubernetes_cluster_role" "admin" {
  count = var.create_admin_role ? 1 : 0

  metadata {
    name = "${local.cluster_name_k8s}-cluster-admin"
    labels = {
      "managed-by" = "terraform"
    }
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }

  rule {
    non_resource_urls = ["*"]
    verbs             = ["*"]
  }

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter
  ]
}

# Developer Role (read + limited write access)
resource "kubernetes_cluster_role" "developer" {
  count = var.create_developer_role ? 1 : 0

  metadata {
    name = "${local.cluster_name_k8s}-developer"
    labels = {
      "managed-by" = "terraform"
    }
  }

  # Read access to most resources
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "configmaps", "secrets", "persistentvolumeclaims", "events"]
    verbs      = ["get", "list", "watch"]
  }

  # Deployments and related
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  # Jobs and CronJobs
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Argo Workflows
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflows", "workflowtemplates", "cronworkflows", "clusterworkflowtemplates"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter
  ]
}

# Read-only Role
resource "kubernetes_cluster_role" "readonly" {
  count = var.create_readonly_role ? 1 : 0

  metadata {
    name = "${local.cluster_name_k8s}-readonly"
    labels = {
      "managed-by" = "terraform"
    }
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter
  ]
}

# =============================================================================
# INGRESS CONTROLLER (NGINX)
# =============================================================================

resource "helm_release" "nginx_ingress" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "nginx" ? 1 : 0

  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.nginx_ingress_version
  namespace        = var.ingress_controller_namespace
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

  values = [
    yamlencode({
      controller = {
        replicaCount = var.ingress_controller_replicas

        service = {
          type = var.ingress_service_type
          annotations = var.ingress_service_type == "LoadBalancer" ? merge(
            {
              "service.beta.kubernetes.io/aws-load-balancer-type"            = "nlb"
              "service.beta.kubernetes.io/aws-load-balancer-scheme"          = var.ingress_load_balancer_scheme
              "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
            },
            var.ingress_service_annotations
          ) : var.ingress_service_annotations
        }

        resources = {
          requests = {
            cpu    = var.ingress_controller_cpu_request
            memory = var.ingress_controller_memory_request
          }
          limits = {
            cpu    = var.ingress_controller_cpu_limit
            memory = var.ingress_controller_memory_limit
          }
        }

        metrics = {
          enabled = var.enable_ingress_metrics
          serviceMonitor = {
            enabled = false # No Prometheus/Grafana
          }
        }

        admissionWebhooks = {
          enabled = true
        }

        config = var.nginx_ingress_config
      }

      defaultBackend = {
        enabled = var.enable_default_backend
      }
    })
  ]

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter
  ]
}

# =============================================================================
# INGRESS CONTROLLER (AWS ALB)
# =============================================================================

# IAM Role for AWS Load Balancer Controller
resource "aws_iam_role" "alb_controller" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? 1 : 0

  name = "${local.cluster_name}-alb-controller-role"

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
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:${var.ingress_controller_namespace}:aws-load-balancer-controller"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM Policy for ALB Controller (AWS managed policy)
resource "aws_iam_role_policy_attachment" "alb_controller" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  role       = aws_iam_role.alb_controller[0].name
}

# Additional policy for ALB Controller
resource "aws_iam_policy" "alb_controller" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? 1 : 0

  name        = "${local.cluster_name}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller_custom" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? 1 : 0

  policy_arn = aws_iam_policy.alb_controller[0].arn
  role       = aws_iam_role.alb_controller[0].name
}

resource "helm_release" "alb_controller" {
  count = var.deploy_ingress_controller && var.ingress_controller_type == "alb" ? 1 : 0

  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = var.alb_controller_version
  namespace        = var.ingress_controller_namespace
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

  values = [
    yamlencode({
      clusterName = var.cluster_name

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller[0].arn
        }
      }

      replicaCount = var.ingress_controller_replicas

      resources = {
        requests = {
          cpu    = var.ingress_controller_cpu_request
          memory = var.ingress_controller_memory_request
        }
        limits = {
          cpu    = var.ingress_controller_cpu_limit
          memory = var.ingress_controller_memory_limit
        }
      }

      vpcId  = var.vpc_id
      region = var.region

      enableShield = false
      enableWaf    = false
      enableWafv2  = false
    })
  ]

  depends_on = [
    null_resource.verify_k8s_api,
    null_resource.verify_karpenter,
    aws_iam_role_policy_attachment.alb_controller,
    aws_iam_role_policy_attachment.alb_controller_custom
  ]
}

# =============================================================================
# RESOURCE QUOTAS
# =============================================================================

resource "kubernetes_resource_quota" "namespace_quotas" {
  for_each = var.deploy_resource_quotas ? var.resource_quotas : {}

  metadata {
    name      = "${each.key}-quota"
    namespace = each.key
  }

  spec {
    hard = each.value
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# LIMIT RANGES
# =============================================================================

resource "kubernetes_limit_range" "namespace_limits" {
  for_each = var.deploy_limit_ranges ? var.limit_ranges : {}

  metadata {
    name      = "${each.key}-limits"
    namespace = each.key
  }

  spec {
    limit {
      type = "Container"
      default = lookup(each.value, "default", {
        cpu    = "500m"
        memory = "512Mi"
      })
      default_request = lookup(each.value, "default_request", {
        cpu    = "100m"
        memory = "128Mi"
      })
      max = lookup(each.value, "max", {})
      min = lookup(each.value, "min", {})
    }
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# NETWORK POLICIES (Optional)
# =============================================================================

resource "kubernetes_network_policy" "deny_all_ingress" {
  for_each = var.deploy_network_policies ? toset(var.namespaces) : toset([])

  metadata {
    name      = "deny-all-ingress"
    namespace = each.value
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # Empty spec with policy_types = ["Ingress"] denies all ingress by default
  }

  depends_on = [kubernetes_namespace.namespaces]
}

resource "kubernetes_network_policy" "allow_same_namespace" {
  for_each = var.deploy_network_policies ? toset(var.namespaces) : toset([])

  metadata {
    name      = "allow-same-namespace"
    namespace = each.value
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = each.value
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# POD SECURITY STANDARDS (via Labels)
# =============================================================================

resource "kubernetes_labels" "pod_security_standards" {
  for_each = var.enforce_pod_security_standards ? toset(var.namespaces) : toset([])

  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = each.value
  }

  labels = {
    "pod-security.kubernetes.io/enforce" = var.pod_security_level
    "pod-security.kubernetes.io/audit"   = var.pod_security_level
    "pod-security.kubernetes.io/warn"    = var.pod_security_level
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# =============================================================================
# NODECLAIM CLEANER
# =============================================================================

# Service Account for NodeClaim Cleaner
resource "kubernetes_service_account_v1" "nodeclaim_cleaner" {
  count = var.enable_nodeclaim_cleaner && var.enable_karpenter ? 1 : 0

  metadata {
    name      = "nodeclaim-cleaner"
    namespace = "kube-system"
    labels = {
      app                            = "nodeclaim-cleaner"
      "app.kubernetes.io/managed-by" = "quantum-terraform"
    }
  }
}

# ClusterRole for NodeClaim Cleaner
resource "kubernetes_cluster_role_v1" "nodeclaim_cleaner" {
  count = var.enable_nodeclaim_cleaner && var.enable_karpenter ? 1 : 0

  metadata {
    name = "nodeclaim-cleaner"
    labels = {
      app                            = "nodeclaim-cleaner"
      "app.kubernetes.io/managed-by" = "quantum-terraform"
    }
  }

  rule {
    api_groups = ["karpenter.sh"]
    resources  = ["nodeclaims"]
    verbs      = ["get", "list", "watch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

# ClusterRoleBinding for NodeClaim Cleaner
resource "kubernetes_cluster_role_binding_v1" "nodeclaim_cleaner" {
  count = var.enable_nodeclaim_cleaner && var.enable_karpenter ? 1 : 0

  metadata {
    name = "nodeclaim-cleaner"
    labels = {
      app                            = "nodeclaim-cleaner"
      "app.kubernetes.io/managed-by" = "quantum-terraform"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.nodeclaim_cleaner[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.nodeclaim_cleaner[0].metadata[0].name
    namespace = "kube-system"
  }
}

# Deployment for NodeClaim Cleaner
resource "kubernetes_deployment_v1" "nodeclaim_cleaner" {
  count = var.enable_nodeclaim_cleaner && var.enable_karpenter ? 1 : 0

  metadata {
    name      = "nodeclaim-cleaner"
    namespace = "kube-system"
    labels = {
      app                            = "nodeclaim-cleaner"
      "app.kubernetes.io/managed-by" = "quantum-terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "nodeclaim-cleaner"
      }
    }

    template {
      metadata {
        labels = {
          app = "nodeclaim-cleaner"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.nodeclaim_cleaner[0].metadata[0].name

        container {
          name  = "nodeclaim-cleaner"
          image = var.nodeclaim_cleaner_image

          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            while true; do
              NOW=$(date +%s)
              kubectl get nodeclaims -A --no-headers \
                -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.conditions[?(@.type=='Ready')].status,AGE:.metadata.creationTimestamp" | while read ns name status created; do
                created_sec=$(date -d "$created" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null)
                if [ -n "$created_sec" ]; then
                  age=$((NOW - created_sec))
                  echo "Run at $(date +"%Y-%m-%d %H:%M:%S")............."
                  if [ "$status" = "False" ] || [ "$status" = "Unknown" ]; then
                    if [ $age -gt ${var.nodeclaim_cleaner_threshold_seconds} ]; then
                      echo "Deleting unready NodeClaim $name in namespace $ns (age $${age}s, status=$${status})"
                      kubectl delete nodeclaim -n $ns $name
                    fi
                  fi
                fi
              done
              sleep ${var.nodeclaim_cleaner_interval_seconds}
            done
            EOT
          ]

          resources {
            requests = {
              cpu    = var.nodeclaim_cleaner_cpu_request
              memory = var.nodeclaim_cleaner_memory_request
            }
            limits = {
              cpu    = var.nodeclaim_cleaner_cpu_limit
              memory = var.nodeclaim_cleaner_memory_limit
            }
          }
        }

        restart_policy = "Always"

        # Schedule on managed nodes only, not on Karpenter nodes
        node_selector = {
          "eks.amazonaws.com/nodegroup" = "${var.project_name}-${var.client_name}-node-group"
        }

        # Tolerate not-ready and unreachable nodes
        toleration {
          key                = "node.kubernetes.io/not-ready"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = 300
        }

        toleration {
          key                = "node.kubernetes.io/unreachable"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = 300
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding_v1.nodeclaim_cleaner
  ]
}
# =============================================================================
# KARPENTER MANIFESTS (EC2NodeClass & NodePool)
# =============================================================================

# EC2NodeClass - defines instance configuration for Karpenter
resource "kubectl_manifest" "karpenter_ec2_nodeclass" {
  count = var.create_karpenter_manifests ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1beta1"
    kind       = "EC2NodeClass"
    metadata = {
      name = var.karpenter_nodeclass_name
    }
    spec = {
      amiFamily                  = var.karpenter_ami_family
      role                       = var.karpenter_instance_profile_arn
      subnetSelectorTerms        = [for subnet_id in var.karpenter_subnet_ids : { id = subnet_id }]
      securityGroupSelectorTerms = [for sg_id in var.karpenter_security_group_ids : { id = sg_id }]
      tags = merge({
        "Name"    = "${var.project_name}-${var.client_name}-karpenter-node"
        "Cluster" = var.cluster_name
      }, var.karpenter_node_tags, var.tags)
      blockDeviceMappings = [for bdm in var.karpenter_block_device_mappings : {
        deviceName = bdm.device_name
        ebs = {
          volumeSize          = "${lookup(bdm.ebs, "volume_size", 30)}Gi"
          volumeType          = lookup(bdm.ebs, "volume_type", "gp3")
          deleteOnTermination = lookup(bdm.ebs, "delete_on_termination", true)
          encrypted           = lookup(bdm.ebs, "encrypted", true)
        }
      }]
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }
      userData = base64encode(<<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="

--==MYBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
yum install -y amazon-efs-utils nfs-utils

--==MYBOUNDARY==--
EOT
      )
    }
  })

  depends_on = [null_resource.verify_karpenter]
}

# NodePool - defines scaling behavior and node pool configuration
resource "kubectl_manifest" "karpenter_nodepool" {
  count = var.create_karpenter_manifests ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata = {
      name = var.karpenter_nodepool_name
    }
    spec = {
      template = {
        metadata = {
          labels = var.karpenter_node_labels
        }
        spec = {
          requirements = var.karpenter_requirements

          taints = length(var.karpenter_node_taints) > 0 ? [
            for taint in var.karpenter_node_taints : {
              key    = taint.key
              value  = taint.value != null ? taint.value : null
              effect = taint.effect
            }
          ] : []

          nodeClassRef = {
            name = var.karpenter_nodeclass_name
          }

          labels = merge(
            {
              "karpenter.sh/capacity-type" = "on-demand"
            },
            var.karpenter_node_labels
          )
        }
      }

      limits = var.karpenter_limits != {} ? {
        cpu    = lookup(var.karpenter_limits, "cpu", "1000")
        memory = lookup(var.karpenter_limits, "memory", "1000Gi")
      } : null

      # disruption config - consolidateAfter is only valid with WhenEmpty policy
      disruption = merge(
        {
          consolidationPolicy = var.karpenter_consolidation_policy
          expireAfter         = var.karpenter_expire_after
          budgets = [
            {
              nodes = var.karpenter_disruption_budget_nodes
            }
          ]
        },
        # Only include consolidateAfter when policy is WhenEmpty
        var.karpenter_consolidation_policy == "WhenEmpty" ? {
          consolidateAfter = var.karpenter_consolidate_after
        } : {}
      )

      weight = 10
    }
  })

  depends_on = [
    null_resource.verify_karpenter,
    kubectl_manifest.karpenter_ec2_nodeclass
  ]
}

# =============================================================================
# Cleanup Script for Post Cluster Setup IAM Resources
# =============================================================================
# This ensures all IAM roles and policies created for ALB controller are cleaned up on destroy

resource "null_resource" "cleanup_post_cluster_iam_resources" {
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
      
      echo "=== Cleaning up Post Cluster Setup IAM resources for cluster: $CLUSTER_NAME ==="
      
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
      
      # Cleanup ALB controller role and policy
      cleanup_role "$CLUSTER_NAME-alb-controller-role"
      cleanup_policy "$CLUSTER_NAME-alb-controller-policy"
      
      echo "=== Post Cluster Setup IAM resources cleanup completed ==="
    EOT
  }
}