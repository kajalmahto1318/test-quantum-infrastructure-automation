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

# Get current AWS region
data "aws_region" "current" {}

locals {
  cluster_name = "${var.project_name}-${var.client_name}"

  common_tags = merge(
    var.tags,
    {
      Module = "EFS"
    }
  )
}

# EFS Security Group
resource "aws_security_group" "efs" {
  name        = "${local.cluster_name}-efs-sg"
  description = "Security group for EFS mount targets"
  vpc_id      = var.vpc_id

  # NFS from custom EKS node security group
  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  # NFS from EKS cluster primary security group (auto-created by EKS, attached to all nodes)
  dynamic "ingress" {
    for_each = var.cluster_primary_security_group_id != null ? [1] : []
    content {
      description     = "NFS from EKS cluster primary security group"
      from_port       = 2049
      to_port         = 2049
      protocol        = "tcp"
      security_groups = [var.cluster_primary_security_group_id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-efs-sg" })
}

# EFS File System
resource "aws_efs_file_system" "main" {
  creation_token = "${local.cluster_name}-efs"
  encrypted      = var.encrypted
  kms_key_id     = var.kms_key_id

  performance_mode                = var.performance_mode
  throughput_mode                 = var.throughput_mode
  provisioned_throughput_in_mibps = var.throughput_mode == "provisioned" ? var.provisioned_throughput_in_mibps : null

  dynamic "lifecycle_policy" {
    for_each = var.lifecycle_policy_transition_to_ia != null ? [1] : []
    content {
      transition_to_ia = var.lifecycle_policy_transition_to_ia
    }
  }

  dynamic "lifecycle_policy" {
    for_each = var.lifecycle_policy_transition_to_primary_storage_class != null ? [1] : []
    content {
      transition_to_primary_storage_class = var.lifecycle_policy_transition_to_primary_storage_class
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.cluster_name}-efs"
    }
  )
}

# EFS Mount Targets
resource "aws_efs_mount_target" "main" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# EFS Access Point (optional, for pod-level isolation)
resource "aws_efs_access_point" "main" {
  count = var.create_access_point ? 1 : 0

  file_system_id = aws_efs_file_system.main.id

  posix_user {
    gid = var.access_point_gid
    uid = var.access_point_uid
  }

  root_directory {
    path = var.access_point_root_path

    creation_info {
      owner_gid   = var.access_point_gid
      owner_uid   = var.access_point_uid
      permissions = var.access_point_permissions
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.cluster_name}-efs-ap"
    }
  )
}

# EFS Backup Policy
resource "aws_efs_backup_policy" "main" {
  count = var.enable_backup ? 1 : 0

  file_system_id = aws_efs_file_system.main.id

  backup_policy {
    status = "ENABLED"
  }
}

# EFS CSI Driver IAM Role (IRSA)
resource "aws_iam_role" "efs_csi_driver" {
  count = var.deploy_efs_csi_driver ? 1 : 0

  name = "${local.cluster_name}-efs-csi-driver-role"

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
            "${replace(var.oidc_provider_arn, "/^(.*provider/)/", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "efs_csi_driver" {
  count = var.deploy_efs_csi_driver ? 1 : 0

  name        = "${local.cluster_name}-efs-csi-driver-policy"
  description = "IAM policy for EFS CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:TagResource"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = "elasticfilesystem:DeleteAccessPoint"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/efs.csi.aws.com/cluster" = "true"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  count = var.deploy_efs_csi_driver ? 1 : 0

  policy_arn = aws_iam_policy.efs_csi_driver[0].arn
  role       = aws_iam_role.efs_csi_driver[0].name
}

# EFS CSI Driver Helm Release
resource "helm_release" "efs_csi_driver" {
  count = var.deploy_efs_csi_driver ? 1 : 0

  name       = "aws-efs-csi-driver"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver/"
  chart      = "aws-efs-csi-driver"
  version    = var.efs_csi_driver_version

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
    name  = "controller.serviceAccount.create"
    value = true
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "efs-csi-controller-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.efs_csi_driver[0].arn
  }

  set {
    name  = "node.serviceAccount.create"
    value = true
  }

  set {
    name  = "node.serviceAccount.name"
    value = "efs-csi-node-sa"
  }

  depends_on = [
    aws_iam_role_policy_attachment.efs_csi_driver,
    aws_efs_mount_target.main
  ]
}

# Storage Class for EFS
resource "kubernetes_storage_class" "efs" {
  count = var.create_storage_class ? 1 : 0

  metadata {
    name = "efs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = var.make_default_storage_class ? "true" : "false"
    }
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = var.storage_class_reclaim_policy

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.main.id
    directoryPerms   = var.storage_class_directory_perms
    basePath         = var.storage_class_base_path
  }

  mount_options = var.storage_class_mount_options

  depends_on = [helm_release.efs_csi_driver]
}

# Persistent Volume for static provisioning (optional)
resource "kubernetes_persistent_volume" "efs" {
  count = var.create_persistent_volume ? 1 : 0

  metadata {
    name = "${local.cluster_name}-efs-pv"
  }

  spec {
    capacity = {
      storage = var.pv_capacity
    }
    volume_mode                      = "Filesystem"
    access_modes                     = var.pv_access_modes
    persistent_volume_reclaim_policy = var.pv_reclaim_policy
    storage_class_name               = var.create_storage_class ? kubernetes_storage_class.efs[0].metadata[0].name : "efs-sc"

    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = var.create_access_point ? "${aws_efs_file_system.main.id}::${aws_efs_access_point.main[0].id}" : aws_efs_file_system.main.id
      }
    }
  }

  depends_on = [helm_release.efs_csi_driver]
}

# Create namespace for PVC if it doesn't exist
resource "kubernetes_namespace" "pvc_namespace" {
  count = var.create_persistent_volume ? 1 : 0

  metadata {
    name = var.pvc_namespace
    labels = {
      "managed-by" = "terraform"
      "module"     = "storage"
    }
  }

  lifecycle {
    ignore_changes        = all
    create_before_destroy = false
  }
}

# PersistentVolumeClaim for EFS
resource "kubernetes_persistent_volume_claim" "efs" {
  count = var.create_persistent_volume ? 1 : 0

  metadata {
    name      = var.pvc_name
    namespace = kubernetes_namespace.pvc_namespace[0].metadata[0].name
  }

  spec {
    access_modes = var.pv_access_modes
    resources {
      requests = {
        storage = var.pvc_size
      }
    }
    storage_class_name = var.create_storage_class ? kubernetes_storage_class.efs[0].metadata[0].name : "efs-sc"
    volume_name        = kubernetes_persistent_volume.efs[0].metadata[0].name
  }

  # Don't wait for PVC to bind - it can timeout with Terraform's rate limiter
  # The PVC will bind asynchronously when a pod mounts it
  wait_until_bound = false

  depends_on = [kubernetes_persistent_volume.efs, kubernetes_namespace.pvc_namespace]
}

# =============================================================================
# CLEANUP ORPHANED IAM RESOURCES ON DESTROY
# =============================================================================
# Sometimes IAM resources are left behind due to dependency issues.
# This ensures they are cleaned up during destroy.

resource "null_resource" "cleanup_storage_iam_resources" {
  triggers = {
    cluster_name = local.cluster_name
    region       = data.aws_region.current.id
  }

  # On destroy, clean up any orphaned IAM resources
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Cleaning up EFS CSI Driver IAM resources for cluster: ${self.triggers.cluster_name} ==="
      
      ROLE_NAME="${self.triggers.cluster_name}-efs-csi-driver-role"
      POLICY_NAME="${self.triggers.cluster_name}-efs-csi-driver-policy"
      POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME"
      
      # Detach policy from role
      echo "Detaching policy from role..."
      aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
      
      # Delete the policy
      echo "Deleting policy: $POLICY_NAME"
      aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
      
      # Delete the role
      echo "Deleting role: $ROLE_NAME"
      aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
      
      echo "=== EFS CSI Driver IAM cleanup completed ==="
    EOT
  }
}

# =============================================================================
# Cleanup Script for EFS Resources
# =============================================================================
# Cleans up EFS access points and mount targets if they weren't properly destroyed

resource "null_resource" "cleanup_efs_resources" {
  triggers = {
    cluster_name = local.cluster_name
    region       = data.aws_region.current.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      CLUSTER_NAME="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      
      echo "=== Cleaning up EFS resources for cluster: $CLUSTER_NAME ==="
      
      # Find EFS file systems with the cluster tag
      EFS_IDS=$(aws efs describe-file-systems \
        --query "FileSystems[?Tags[?Key=='Name' && contains(Value, '$CLUSTER_NAME')]].FileSystemId" \
        --output text --region $REGION 2>/dev/null || echo "")
      
      for EFS_ID in $EFS_IDS; do
        if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
          echo "Processing EFS: $EFS_ID"
          
          # Delete access points first
          ACCESS_POINTS=$(aws efs describe-access-points \
            --file-system-id "$EFS_ID" \
            --query 'AccessPoints[*].AccessPointId' \
            --output text --region $REGION 2>/dev/null || echo "")
          
          for AP_ID in $ACCESS_POINTS; do
            if [ -n "$AP_ID" ] && [ "$AP_ID" != "None" ]; then
              echo "  Deleting access point: $AP_ID"
              aws efs delete-access-point --access-point-id "$AP_ID" --region $REGION 2>/dev/null || true
            fi
          done
          
          # Delete mount targets
          MOUNT_TARGETS=$(aws efs describe-mount-targets \
            --file-system-id "$EFS_ID" \
            --query 'MountTargets[*].MountTargetId' \
            --output text --region $REGION 2>/dev/null || echo "")
          
          for MT_ID in $MOUNT_TARGETS; do
            if [ -n "$MT_ID" ] && [ "$MT_ID" != "None" ]; then
              echo "  Deleting mount target: $MT_ID"
              aws efs delete-mount-target --mount-target-id "$MT_ID" --region $REGION 2>/dev/null || true
            fi
          done
          
          # Wait for mount targets to be deleted
          echo "  Waiting for mount targets to be deleted..."
          sleep 30
          
          # Delete the EFS file system
          echo "  Deleting EFS file system: $EFS_ID"
          aws efs delete-file-system --file-system-id "$EFS_ID" --region $REGION 2>/dev/null || true
        fi
      done
      
      echo "=== EFS resources cleanup completed ==="
    EOT
  }
}
