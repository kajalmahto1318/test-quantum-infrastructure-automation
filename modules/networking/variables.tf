variable "project_name" {
  description = "Project name for resource naming"
  type        = string
}

variable "client_name" {
  description = "Client name for resource naming"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS support in the VPC"
  type        = bool
  default     = true
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs"
  type        = list(string)
}

variable "nat_gateway" {
  description = "Whether to create a NAT Gateway"
  type        = bool
}

variable "internet_gateway" {
  description = "Whether to create an Internet Gateway"
  type        = bool
}

variable "region" {
  description = "AWS region for ENI cleanup operations"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources."
  type        = map(string)
  default     = {}
}