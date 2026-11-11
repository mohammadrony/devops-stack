output "state_bucket_name" {
  description = "S3 bucket name for Terraform remote state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "aws_region" {
  description = "AWS region of the remote state bucket."
  value       = var.aws_region
}
