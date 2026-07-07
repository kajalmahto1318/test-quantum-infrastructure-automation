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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.client_name}"

  common_tags = merge(
    var.tags,
    {
      Module = "Karpenter"
    }
  )
}

# Wait for EKS cluster API to be fully ready before applying kubectl resources
resource "time_sleep" "wait_for_cluster" {
  create_duration = "60s"

  triggers = {
    cluster_endpoint = var.cluster_endpoint
  }
}

# Karpenter Controller IAM Role (IRSA)
resource "aws_iam_role" "karpenter_controller" {
  name = "${local.cluster_name}-karpenter-controller-role"

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
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:${var.karpenter_namespace}:karpenter"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${local.cluster_name}-karpenter-controller-policy"
  description = "IAM policy for Karpenter controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:aws:ec2:${var.region}::image/*",
          "arn:aws:ec2:${var.region}::snapshot/*",
          "arn:aws:ec2:${var.region}:*:security-group/*",
          "arn:aws:ec2:${var.region}:*:subnet/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*"
        ]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate"
        ]
        Resource = [
          "arn:aws:ec2:${var.region}:*:fleet/*",
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:volume/*",
          "arn:aws:ec2:${var.region}:*:network-interface/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*",
          "arn:aws:ec2:${var.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:aws:ec2:${var.region}:*:fleet/*",
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:volume/*",
          "arn:aws:ec2:${var.region}:*:network-interface/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*",
          "arn:aws:ec2:${var.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateFleet",
              "CreateLaunchTemplate"
            ]
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:aws:ec2:${var.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = [
              "karpenter.sh/nodeclaim",
              "Name"
            ]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = [
          "arn:aws:ec2:${var.region}:*:instance/*",
          "arn:aws:ec2:${var.region}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.region
          }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.region}::parameter/aws/service/*"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },
      {
        Sid    = "AllowInterruptionQueueActions"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = var.node_iam_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileCreationActions"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileTagActions"
        Effect = "Allow"
        Action = [
          "iam:TagInstanceProfile"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"              = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = "iam:GetInstanceProfile"
        Resource = "*"
      },
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.region}:*:cluster/${var.cluster_name}"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}

# SQS Queue for Spot Interruption Handling
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${local.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSWrite"
        Effect = "Allow"
        Principal = {
          Service = [
            "events.amazonaws.com",
            "sqs.amazonaws.com"
          ]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridge Rules for Spot Interruption
resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  name        = "${local.cluster_name}-karpenter-interruption"
  description = "Karpenter interruption rule"

  event_pattern = jsonencode({
    source = ["aws.health", "aws.ec2"]
    detail-type = [
      "EC2 Instance State-change Notification",
      "EC2 Spot Instance Interruption Warning",
      "AWS Health Event"
    ]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_interruption.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Instance Rebalance Recommendation
resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${local.cluster_name}-karpenter-rebalance"
  description = "Karpenter rebalance recommendation rule"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule      = aws_cloudwatch_event_rule.karpenter_rebalance.name
  target_id = "KarpenterRebalanceQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Karpenter Helm Release
resource "helm_release" "karpenter" {
  count = var.deploy_karpenter ? 1 : 0

  name       = "karpenter"
  namespace  = var.karpenter_namespace
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

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

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = var.controller_cpu_request
  }

  set {
    name  = "controller.resources.requests.memory"
    value = var.controller_memory_request
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = var.controller_cpu_limit
  }

  set {
    name  = "controller.resources.limits.memory"
    value = var.controller_memory_limit
  }

  set {
    name  = "replicas"
    value = var.controller_replicas
  }

  depends_on = [
    aws_iam_role_policy_attachment.karpenter_controller,
    aws_sqs_queue_policy.karpenter_interruption,
    aws_cloudwatch_event_target.karpenter_interruption,
    aws_cloudwatch_event_target.karpenter_rebalance
  ]
}

# =============================================================================
# EC2NodeClass - Defines EC2 configuration for Karpenter nodes
# COMMENTED OUT: Kubernetes cluster becomes unavailable during destruction,
# causing kubectl_manifest to hang indefinitely. Will be recreated on onboard.
# =============================================================================
# resource "kubectl_manifest" "karpenter_node_class" {
#   count = var.deploy_karpenter && var.create_default_nodepool ? 1 : 0
#
#   server_side_apply = true
#   force_conflicts   = true
#   wait              = true
#   
#   yaml_body = yamlencode({
#     apiVersion = "karpenter.k8s.aws/v1beta1"
#     kind       = "EC2NodeClass"
#     metadata = {
#       name = "default"
#     }
#     spec = {
#       amiFamily = var.ami_family
#       role      = var.node_iam_role_name
#
#       subnetSelectorTerms = [
#         {
#           tags = {
#             "karpenter.sh/discovery" = var.cluster_name
#           }
#         }
#       ]
#
#       securityGroupSelectorTerms = [
#         {
#           tags = {
#             "karpenter.sh/discovery" = var.cluster_name
#           }
#         }
#       ]
#
#       # Block device mappings for root volume
#       blockDeviceMappings = [
#         {
#           deviceName = "/dev/xvda"
#           ebs = {
#             volumeSize          = "${var.node_volume_size}Gi"
#             volumeType          = var.node_volume_type
#             encrypted           = true
#             deleteOnTermination = true
#           }
#         }
#       ]
#
#       # User data for node configuration
#       userData = var.node_user_data
#
#       # Tags applied to provisioned instances
#       tags = merge(
#         local.common_tags,
#         {
#           "Name" = "${local.cluster_name}-karpenter-node"
#         }
#       )
#
#       # Metadata options for IMDSv2
#       metadataOptions = {
#         httpEndpoint            = "enabled"
#         httpProtocolIPv6        = "disabled"
#         httpPutResponseHopLimit = 2
#         httpTokens              = "required"
#       }
#     }
#   })
#
#   depends_on = [
#     helm_release.karpenter,
#     time_sleep.wait_for_cluster
#   ]
# }

# =============================================================================
# NodePool - Defines pod scheduling constraints and node provisioning limits
# COMMENTED OUT: Moved to post_cluster_setup module to ensure proper ordering
# and avoid kubectl_manifest hanging during destruction.
# =============================================================================
# resource "kubectl_manifest" "karpenter_nodepool" {
#   count = var.deploy_karpenter && var.create_default_nodepool ? 1 : 0
#
#   server_side_apply = true
#   force_conflicts   = true
#   wait              = true
#   
#   yaml_body = yamlencode({
#     apiVersion = "karpenter.sh/v1beta1"
#     kind       = "NodePool"
#     metadata = {
#       name = "default"
#     }
#     spec = {
#       template = {
#         metadata = {
#           labels = var.nodepool_labels
#         }
#         spec = {
#           nodeClassRef = {
#             name = "default"
#           }
#
#           # Instance requirements
#           requirements = [
#             {
#               key      = "kubernetes.io/arch"
#               operator = "In"
#               values   = var.architectures
#             },
#             {
#               key      = "kubernetes.io/os"
#               operator = "In"
#               values   = ["linux"]
#             },
#             {
#               key      = "karpenter.sh/capacity-type"
#               operator = "In"
#               values   = var.capacity_types
#             },
#             {
#               key      = "karpenter.k8s.aws/instance-category"
#               operator = "In"
#               values   = var.instance_categories
#             },
#             {
#               key      = "karpenter.k8s.aws/instance-cpu"
#               operator = "In"
#               values   = var.instance_cpu_values
#             },
#             {
#               key      = "karpenter.k8s.aws/instance-memory"
#               operator = "Gt"
#               values   = [var.min_instance_memory]
#             }
#           ]
#
#           # Taints for workload isolation (optional)
#           taints = var.nodepool_taints
#
#           # Kubelet configuration
#           kubelet = {
#             maxPods = var.max_pods_per_node
#           }
#         }
#       }
#
#       # Limits on total resources Karpenter can provision
#       limits = {
#         cpu    = var.nodepool_cpu_limit
#         memory = var.nodepool_memory_limit
#       }
#
#       # Disruption settings for consolidation and updates
#       disruption = {
#         consolidationPolicy = var.consolidation_policy
#         consolidateAfter    = var.consolidation_policy == "WhenEmpty" ? var.consolidate_after : null
#
#         # Budget to control how many nodes can be disrupted at once
#         budgets = [
#           {
#             nodes = var.disruption_budget_nodes
#           }
#         ]
#       }
#
#       # Weight for scheduling priority (higher = preferred)
#       weight = var.nodepool_weight
#     }
#   })
#
#   depends_on = [
#     helm_release.karpenter,
#     time_sleep.wait_for_cluster
#   ]
# }

# =============================================================================
# KARPENTER CLEANUP ON DESTROY
# =============================================================================
# Karpenter creates instance profiles dynamically for EC2 nodes.
# These need to be cleaned up when destroying the infrastructure.

resource "null_resource" "cleanup_karpenter_instance_profiles" {
  count = var.deploy_karpenter ? 1 : 0

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  # On destroy, clean up any Karpenter-created instance profiles
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Cleaning up Karpenter-created instance profiles for cluster: ${self.triggers.cluster_name} ==="
      
      # Find all instance profiles with Karpenter tags for this cluster
      INSTANCE_PROFILES=$(aws iam list-instance-profiles \
        --query "InstanceProfiles[?contains(InstanceProfileName, '${self.triggers.cluster_name}_')].InstanceProfileName" \
        --output text --region ${self.triggers.region} 2>/dev/null || echo "")
      
      if [ -z "$INSTANCE_PROFILES" ]; then
        echo "No Karpenter instance profiles found for cluster ${self.triggers.cluster_name}"
        exit 0
      fi
      
      for PROFILE in $INSTANCE_PROFILES; do
        echo "Processing instance profile: $PROFILE"
        
        # Get roles attached to the instance profile
        ROLES=$(aws iam get-instance-profile --instance-profile-name "$PROFILE" \
          --query 'InstanceProfile.Roles[*].RoleName' --output text --region ${self.triggers.region} 2>/dev/null || echo "")
        
        # Remove roles from instance profile
        for ROLE in $ROLES; do
          echo "  Removing role $ROLE from instance profile $PROFILE"
          aws iam remove-role-from-instance-profile \
            --instance-profile-name "$PROFILE" \
            --role-name "$ROLE" --region ${self.triggers.region} 2>/dev/null || true
        done
        
        # Delete the instance profile
        echo "  Deleting instance profile: $PROFILE"
        aws iam delete-instance-profile --instance-profile-name "$PROFILE" --region ${self.triggers.region} 2>/dev/null || true
      done
      
      echo "=== Karpenter instance profile cleanup completed ==="
    EOT
  }

  depends_on = [helm_release.karpenter]
}

# =============================================================================
# KARPENTER EC2 RESOURCES CLEANUP ON DESTROY
# =============================================================================
# Cleans up Karpenter-created EC2 resources: fleets, launch templates, and instances

resource "null_resource" "cleanup_karpenter_ec2_resources" {
  count = var.deploy_karpenter ? 1 : 0

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      CLUSTER_NAME="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      
      echo "=== Cleaning up Karpenter EC2 resources for cluster: $CLUSTER_NAME ==="
      
      # Terminate EC2 instances created by Karpenter
      echo "Looking for Karpenter-managed EC2 instances..."
      INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        echo "Terminating Karpenter instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
        
        # Wait for instances to terminate
        echo "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
      else
        echo "No Karpenter instances found"
      fi
      
      # Delete EC2 Fleets created by Karpenter
      echo "Looking for Karpenter EC2 fleets..."
      FLEET_IDS=$(aws ec2 describe-fleets \
        --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
        --query 'Fleets[*].FleetId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$FLEET_IDS" ] && [ "$FLEET_IDS" != "None" ]; then
        for FLEET_ID in $FLEET_IDS; do
          echo "Deleting fleet: $FLEET_ID"
          aws ec2 delete-fleets --fleet-ids "$FLEET_ID" --terminate-instances --region $REGION 2>/dev/null || true
        done
      else
        echo "No Karpenter fleets found"
      fi
      
      # Delete Launch Templates created by Karpenter
      echo "Looking for Karpenter launch templates..."
      LAUNCH_TEMPLATES=$(aws ec2 describe-launch-templates \
        --filters "Name=tag:karpenter.sh/nodepool,Values=*" \
        --query 'LaunchTemplates[*].LaunchTemplateId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$LAUNCH_TEMPLATES" ] && [ "$LAUNCH_TEMPLATES" != "None" ]; then
        for LT_ID in $LAUNCH_TEMPLATES; do
          echo "Deleting launch template: $LT_ID"
          aws ec2 delete-launch-template --launch-template-id "$LT_ID" --region $REGION 2>/dev/null || true
        done
      else
        echo "No Karpenter launch templates found"
      fi
      
      echo "=== Karpenter EC2 resources cleanup completed ==="
    EOT
  }

  depends_on = [helm_release.karpenter]
}

# =============================================================================
# KARPENTER SQS/EVENTBRIDGE CLEANUP ON DESTROY
# =============================================================================
# Cleans up SQS queue and EventBridge rules if they weren't properly destroyed

resource "null_resource" "cleanup_karpenter_event_resources" {
  count = var.deploy_karpenter ? 1 : 0

  triggers = {
    cluster_name = var.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      CLUSTER_NAME="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      
      echo "=== Cleaning up Karpenter SQS/EventBridge resources for cluster: $CLUSTER_NAME ==="
      
      # Delete EventBridge rule targets first, then rules
      for RULE_NAME in "$CLUSTER_NAME-karpenter-interruption" "$CLUSTER_NAME-karpenter-rebalance"; do
        echo "Processing EventBridge rule: $RULE_NAME"
        
        # List and remove targets
        TARGETS=$(aws events list-targets-by-rule --rule "$RULE_NAME" --query 'Targets[*].Id' --output text --region $REGION 2>/dev/null || echo "")
        if [ -n "$TARGETS" ] && [ "$TARGETS" != "None" ]; then
          for TARGET_ID in $TARGETS; do
            echo "  Removing target: $TARGET_ID"
            aws events remove-targets --rule "$RULE_NAME" --ids "$TARGET_ID" --region $REGION 2>/dev/null || true
          done
        fi
        
        # Delete the rule
        echo "  Deleting rule: $RULE_NAME"
        aws events delete-rule --name "$RULE_NAME" --region $REGION 2>/dev/null || true
      done
      
      # Delete SQS queue
      QUEUE_URL=$(aws sqs get-queue-url --queue-name "$CLUSTER_NAME-karpenter-interruption" --query 'QueueUrl' --output text --region $REGION 2>/dev/null || echo "")
      if [ -n "$QUEUE_URL" ] && [ "$QUEUE_URL" != "None" ]; then
        echo "Deleting SQS queue: $QUEUE_URL"
        aws sqs delete-queue --queue-url "$QUEUE_URL" --region $REGION 2>/dev/null || true
      else
        echo "SQS queue not found"
      fi
      
      echo "=== Karpenter SQS/EventBridge resources cleanup completed ==="
    EOT
  }

  depends_on = [helm_release.karpenter]
}
