terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
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

# Networking Module - VPC, Subnets, NAT, IGW

data "aws_availability_zones" "available" {}

locals {
  # Common Name - must match EKS cluster naming for Karpenter discovery
  name = "${var.project_name}-${var.client_name}"

  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  common_tags = merge(
    var.tags,
    {
      Module = "Networking"
    }
  )
}

# =============================================================================
# VPC
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = merge(
    local.common_tags,
    {
      "Name"                                = "${local.name}-vpc"
      "kubernetes.io/cluster/${local.name}" = "shared"
    }
  )
}

# =============================================================================
# ENI CLEANUP FOR CLEAN DESTROY
# =============================================================================
# This cleans up orphaned ENIs (from Load Balancers, EKS, etc.) before subnet deletion

resource "null_resource" "cleanup_enis_before_destroy" {
  # Trigger on VPC ID - this runs on destroy BEFORE subnets are deleted
  triggers = {
    vpc_id = aws_vpc.main.id
    region = var.region
  }

  # On destroy, clean up any orphaned ENIs in the VPC
  provisioner "local-exec" {
    when    = destroy
    command = "/bin/bash ${path.module}/cleanup_enis.sh ${self.triggers.region} ${self.triggers.vpc_id}"
  }
}

# Wait after ENI cleanup before proceeding with subnet deletion
resource "time_sleep" "wait_for_eni_cleanup" {
  destroy_duration = "30s"

  depends_on = [null_resource.cleanup_enis_before_destroy]
}

# =============================================================================
# Internet Gateway
# =============================================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { "Name" = "${local.name}-igw" })
}

# =============================================================================
# Public Subnets
# =============================================================================
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    {
      Type                                  = "public"
      "Name"                                = "${local.name}-public-${count.index}"
      "kubernetes.io/role/elb"              = "1"
      "kubernetes.io/cluster/${local.name}" = "shared"
    }
  )

  lifecycle {
    # Ignore changes to tags that might be added by AWS services
    ignore_changes = [tags["kubernetes.io/cluster"]]
  }
}

# =============================================================================
# Private Subnets
# =============================================================================
resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    {
      Type                                  = "private"
      "Name"                                = "${local.name}-private-${count.index}"
      "kubernetes.io/role/internal-elb"     = "1"
      "kubernetes.io/cluster/${local.name}" = "shared"
      "karpenter.sh/discovery"              = local.name
    }
  )

  lifecycle {
    # Ignore changes to tags that might be added by AWS services
    ignore_changes = [tags["kubernetes.io/cluster"]]
  }
}

# =============================================================================
# Elastic IPs for NAT Gateways
# =============================================================================
resource "aws_eip" "nat" {
  count = var.nat_gateway ? 1 : 0

  domain = "vpc"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-nat-eip-${count.index + 1}"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# NAT Gateways
# =============================================================================
resource "aws_nat_gateway" "main" {
  count = var.nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-nat-${count.index + 1}"
    }
  )

  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# Public Route Table
# =============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-public-rt"
    }
  )
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# Private Route Tables
# =============================================================================
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.name}-private-Route-${local.availability_zones[count.index]}"
    }
  )
}

# Private Route Table Routes (to NAT Gateway)
resource "aws_route" "private_nat_gateway" {
  count = var.nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

# Private Route Table Associations
resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
