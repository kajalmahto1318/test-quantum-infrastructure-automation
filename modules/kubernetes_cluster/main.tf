terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 3.0"
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.client_name}"
  project_name = var.project_name
  common_tags = merge(
    var.tags,
    {
      Module = "EKS"
    }
  )
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Cluster Security Group
resource "aws_security_group" "eks_cluster" {
  name        = "${local.cluster_name}-eks-cluster-sg"
  description = "Security group for EKS cluster control plane"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-eks-cluster-sg" })
}

resource "aws_security_group_rule" "eks_cluster_ingress_node" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  type                     = "ingress"
}

# EKS Node Security Group
resource "aws_security_group" "eks_nodes" {
  name        = "${local.cluster_name}-eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name                                          = "${local.cluster_name}-eks-nodes-sg"
      "kubernetes.io/cluster/${local.cluster_name}" = "owned"
      "karpenter.sh/discovery"                      = local.cluster_name
    }
  )
}

resource "aws_security_group_rule" "eks_nodes_ingress_self" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_nodes.id
  type                     = "ingress"
}

resource "aws_security_group_rule" "eks_nodes_ingress_cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  type                     = "ingress"
}

resource "aws_security_group_rule" "eks_nodes_ingress_cluster_https" {
  description              = "Allow pods to communicate with the cluster API Server"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  type                     = "ingress"
}

# =============================================================================
# Cross-Security Group Rules for Karpenter Nodes <-> EKS Managed Nodes
# =============================================================================
# EKS creates its own security group for managed node groups. Karpenter nodes
# use the eks_nodes security group. These rules enable communication between
# pods on managed nodes (CoreDNS, etc.) and pods on Karpenter-provisioned nodes.

# Allow traffic FROM EKS cluster's managed security group TO Karpenter nodes SG
resource "aws_security_group_rule" "eks_nodes_ingress_from_cluster_sg" {
  description              = "Allow all traffic from EKS cluster security group to Karpenter nodes"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  type                     = "ingress"

  depends_on = [aws_eks_cluster.main]
}

# Allow traffic FROM Karpenter nodes SG TO EKS cluster's managed security group
resource "aws_security_group_rule" "eks_cluster_sg_ingress_from_nodes" {
  description              = "Allow all traffic from Karpenter nodes to EKS cluster security group"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.eks_nodes.id
  type                     = "ingress"

  depends_on = [aws_eks_cluster.main]
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # Enable EKS Access Entries (API authentication mode)
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}

# =============================================================================
# EKS Access Entries - Define who can access the cluster
# =============================================================================

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Root account access entry - grants admin access to the AWS account root
resource "aws_eks_access_entry" "root_account" {
  count = var.enable_root_account_access ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "root_account_admin" {
  count = var.enable_root_account_access ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.root_account[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.root_account]
}

# EKS Node Group Role access entry - for managed node groups
resource "aws_eks_access_entry" "node_group" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_node_group.arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}

# Karpenter Node Role access entry - for Karpenter-provisioned nodes
resource "aws_eks_access_entry" "karpenter_nodes" {
  count = var.enable_karpenter_node_access && var.karpenter_node_role_name != "" ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.karpenter_node_role_name}"
  type          = "EC2_LINUX"

  tags = local.common_tags
}

# Custom access entries from variable
resource "aws_eks_access_entry" "custom" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  user_name         = each.value.user_name
  kubernetes_groups = length(each.value.kubernetes_groups) > 0 ? each.value.kubernetes_groups : null

  tags = local.common_tags
}

# Policy associations for custom access entries
resource "aws_eks_access_policy_association" "custom" {
  for_each = merge([
    for entry_key, entry in var.access_entries : {
      for policy_key, policy in entry.policy_associations :
      "${entry_key}-${policy_key}" => {
        cluster_name  = aws_eks_cluster.main.name
        principal_arn = entry.principal_arn
        policy_arn    = policy.policy_arn
        access_scope  = policy.access_scope
      }
    }
  ]...)

  cluster_name  = each.value.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = each.value.access_scope.type == "namespace" ? each.value.access_scope.namespaces : null
  }

  depends_on = [aws_eks_access_entry.custom]
}

# EKS OIDC Provider for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = local.common_tags
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "${local.cluster_name}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node_group.name
}

# Launch Template for EC2 Instance Naming
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.cluster_name}-node-"
  description = "Launch template for EKS managed node group with instance naming"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name                                          = "${local.cluster_name}-node"
        "kubernetes.io/cluster/${local.cluster_name}" = "owned"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      local.common_tags,
      {
        Name = "${local.cluster_name}-node-volume"
      }
    )
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }

  user_data = base64encode(<<-EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==MYBOUNDARY=="

--==MYBOUNDARY==
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
yum install -y amazon-efs-utils nfs-utils

--==MYBOUNDARY==--
EOF
  )
}

# EKS Managed Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = var.node_subnet_ids

  instance_types = var.instance_types
  capacity_type  = var.capacity_type

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = merge(
    {
      "node.kubernetes.io/lifecycle" = var.capacity_type == "SPOT" ? "spot" : "on-demand"
    },
    var.node_labels
  )

  dynamic "taint" {
    for_each = var.node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.cluster_name}-node-group"
    }
  )

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
    aws_launch_template.eks_nodes
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# EKS Addons
resource "aws_eks_addon" "vpc_cni" {
  count = var.enable_vpc_cni_addon ? 1 : 0

  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  count = var.enable_coredns_addon ? 1 : 0

  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  count = var.enable_kube_proxy_addon ? 1 : 0

  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = var.enable_ebs_csi_addon ? 1 : 0

  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver[0].arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.main]
}

# EBS CSI Driver IAM Role (IRSA)
resource "aws_iam_role" "ebs_csi_driver" {
  count = var.enable_ebs_csi_addon ? 1 : 0

  name = "${local.cluster_name}-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  count = var.enable_ebs_csi_addon ? 1 : 0

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver[0].name
}

# ============================================
# Kubeconfig Generation and Secrets Manager Storage
# ============================================

locals {
  kubeconfig = var.store_kubeconfig_in_secrets_manager ? yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = local.cluster_name
      cluster = {
        server                     = aws_eks_cluster.main.endpoint
        certificate-authority-data = aws_eks_cluster.main.certificate_authority[0].data
      }
    }]
    contexts = [{
      name = local.cluster_name
      context = {
        cluster = local.cluster_name
        user    = local.cluster_name
      }
    }]
    current-context = local.cluster_name
    users = [{
      name = local.cluster_name
      user = {
        exec = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "aws"
          args = [
            "eks",
            "get-token",
            "--cluster-name",
            local.cluster_name,
            "--region",
            var.region
          ]
        }
      }
    }]
  }) : null
}

# Store Kubeconfig in AWS Secrets Manager
resource "aws_secretsmanager_secret" "kubeconfig" {
  count = var.store_kubeconfig_in_secrets_manager ? 1 : 0

  name        = "${local.project_name}/eks/kubeconfig"
  description = "Kubeconfig for EKS cluster ${local.cluster_name}"

  # Set to 0 for immediate deletion on destroy (no recovery period)
  recovery_window_in_days = 0

  tags = merge(
    local.common_tags,
    {
      Purpose = "EKSKubeconfig"
    }
  )
}

resource "aws_secretsmanager_secret_version" "kubeconfig" {
  count = var.store_kubeconfig_in_secrets_manager ? 1 : 0

  secret_id = aws_secretsmanager_secret.kubeconfig[0].id

  secret_string = jsonencode({
    cluster_name                  = local.cluster_name
    cluster_endpoint              = aws_eks_cluster.main.endpoint
    cluster_arn                   = aws_eks_cluster.main.arn
    certificate_authority_data    = aws_eks_cluster.main.certificate_authority[0].data
    region                        = var.region
    kubeconfig                    = local.kubeconfig
    aws_cli_update_kubeconfig_cmd = "aws eks update-kubeconfig --region ${var.region} --name ${local.cluster_name}"
    usage_instructions            = "Use the kubeconfig content directly or run the aws cli command to configure kubectl"
  })

  depends_on = [aws_eks_cluster.main]
}

# =============================================================================
# Cleanup Script for EKS IAM Resources
# =============================================================================
# This ensures all IAM roles and policies created for EKS are cleaned up on destroy
# Runs before terraform destroys its own resources to handle any orphaned resources

resource "null_resource" "cleanup_eks_iam_resources" {
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
      
      echo "=== Cleaning up EKS IAM resources for cluster: $CLUSTER_NAME ==="
      
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
      
      # Cleanup EKS cluster role
      cleanup_role "$CLUSTER_NAME-eks-cluster-role"
      
      # Cleanup EKS node group role
      cleanup_role "$CLUSTER_NAME-eks-node-group-role"
      
      # Cleanup EBS CSI driver role
      cleanup_role "$CLUSTER_NAME-ebs-csi-driver-role"
      
      echo "=== EKS IAM resources cleanup completed ==="
    EOT
  }

  # Run cleanup before the cluster is destroyed
  depends_on = [
    aws_eks_cluster.main
  ]
}

# =============================================================================
# Cleanup Script for EKS OIDC Provider
# =============================================================================
# Cleans up the OIDC provider if it wasn't properly destroyed by Terraform

resource "null_resource" "cleanup_eks_oidc_provider" {
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
      
      echo "=== Cleaning up EKS OIDC provider for cluster: $CLUSTER_NAME ==="
      
      # Find OIDC provider ARN for this cluster
      OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text 2>/dev/null || echo "")
      
      for OIDC_ARN in $OIDC_PROVIDERS; do
        if [ -n "$OIDC_ARN" ] && [ "$OIDC_ARN" != "None" ]; then
          # Get the OIDC URL to check if it belongs to our cluster
          OIDC_URL=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" --query 'Url' --output text 2>/dev/null || echo "")
          
          # Check if this OIDC provider is for our EKS cluster (contains our region)
          if echo "$OIDC_URL" | grep -q "eks.$REGION.amazonaws.com"; then
            echo "Found OIDC provider: $OIDC_ARN"
            echo "Deleting OIDC provider..."
            aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" 2>/dev/null || true
            echo "OIDC provider deleted"
          fi
        fi
      done
      
      echo "=== EKS OIDC provider cleanup completed ==="
    EOT
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# =============================================================================
# Cleanup Script for EKS CloudWatch Log Group
# =============================================================================
# Cleans up the CloudWatch log group if it wasn't properly destroyed

resource "null_resource" "cleanup_eks_cloudwatch_logs" {
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
      LOG_GROUP_NAME="/aws/eks/$CLUSTER_NAME/cluster"
      
      echo "=== Cleaning up EKS CloudWatch log group: $LOG_GROUP_NAME ==="
      
      # Check if log group exists and delete it
      if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME'].logGroupName" --output text --region $REGION 2>/dev/null | grep -q "$LOG_GROUP_NAME"; then
        echo "Deleting log group: $LOG_GROUP_NAME"
        aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME" --region $REGION 2>/dev/null || true
        echo "Log group deleted"
      else
        echo "Log group not found"
      fi
      
      echo "=== EKS CloudWatch log group cleanup completed ==="
    EOT
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# =============================================================================
# Cleanup Script for EKS ENIs (Network Interfaces)
# =============================================================================
# Cleans up orphaned ENIs created by EKS

resource "null_resource" "cleanup_eks_enis" {
  triggers = {
    cluster_name = local.cluster_name
    region       = var.region
    vpc_id       = var.vpc_id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      #!/bin/bash
      set -e
      
      CLUSTER_NAME="${self.triggers.cluster_name}"
      REGION="${self.triggers.region}"
      VPC_ID="${self.triggers.vpc_id}"
      
      echo "=== Cleaning up EKS ENIs for cluster: $CLUSTER_NAME ==="
      
      # Find ENIs tagged with the cluster name or in the VPC with EKS description
      ENI_IDS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=description,Values=*EKS*,*eks*,*$CLUSTER_NAME*" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$ENI_IDS" ] && [ "$ENI_IDS" != "None" ]; then
        for ENI_ID in $ENI_IDS; do
          echo "Deleting ENI: $ENI_ID"
          aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region $REGION 2>/dev/null || true
        done
      else
        echo "No orphaned ENIs found"
      fi
      
      # Also look for ENIs with kubernetes.io tags
      ENI_IDS_K8S=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$ENI_IDS_K8S" ] && [ "$ENI_IDS_K8S" != "None" ]; then
        for ENI_ID in $ENI_IDS_K8S; do
          echo "Deleting K8s-tagged ENI: $ENI_ID"
          aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region $REGION 2>/dev/null || true
        done
      fi
      
      echo "=== EKS ENIs cleanup completed ==="
    EOT
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# =============================================================================
# Cleanup Script for EBS Volumes
# =============================================================================
# Cleans up orphaned EBS volumes created by EKS/Kubernetes

resource "null_resource" "cleanup_eks_ebs_volumes" {
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
      
      echo "=== Cleaning up EKS EBS volumes for cluster: $CLUSTER_NAME ==="
      
      # Find EBS volumes with kubernetes.io tags for this cluster
      VOLUME_IDS=$(aws ec2 describe-volumes \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$VOLUME_IDS" ] && [ "$VOLUME_IDS" != "None" ]; then
        for VOLUME_ID in $VOLUME_IDS; do
          echo "Deleting EBS volume: $VOLUME_ID"
          aws ec2 delete-volume --volume-id "$VOLUME_ID" --region $REGION 2>/dev/null || true
        done
      else
        echo "No orphaned EBS volumes found"
      fi
      
      # Also look for volumes tagged with CSIVolumeName
      VOLUME_IDS_CSI=$(aws ec2 describe-volumes \
        --filters "Name=tag-key,Values=CSIVolumeName" "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=*" "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' \
        --output text --region $REGION 2>/dev/null || echo "")
      
      if [ -n "$VOLUME_IDS_CSI" ] && [ "$VOLUME_IDS_CSI" != "None" ]; then
        for VOLUME_ID in $VOLUME_IDS_CSI; do
          # Check if this volume belongs to our cluster
          CLUSTER_TAG=$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query "Volumes[0].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME'].Value" --output text --region $REGION 2>/dev/null || echo "")
          if [ -n "$CLUSTER_TAG" ] && [ "$CLUSTER_TAG" != "None" ]; then
            echo "Deleting CSI EBS volume: $VOLUME_ID"
            aws ec2 delete-volume --volume-id "$VOLUME_ID" --region $REGION 2>/dev/null || true
          fi
        done
      fi
      
      echo "=== EKS EBS volumes cleanup completed ==="
    EOT
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}
