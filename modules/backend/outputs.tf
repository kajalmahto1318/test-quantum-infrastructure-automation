output "s3_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "dynamodb_table" {
  value = aws_dynamodb_table.tfstate_lock.id
}
