resource "aws_s3_bucket" "tfstate" {
  bucket        = var.s3_bucket
  force_destroy = false
  tags          = var.tags
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = var.dynamodb_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = var.tags
}
