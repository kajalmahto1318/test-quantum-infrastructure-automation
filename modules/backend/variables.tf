variable "s3_bucket" {
  description = "Name of the S3 bucket for Terraform state."
  type        = string
}

variable "dynamodb_table" {
  description = "Name of the DynamoDB table for state locking."
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources."
  type        = map(string)
  default     = {}
}
