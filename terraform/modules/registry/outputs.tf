locals {
  repository_arn  = var.create_repository ? aws_ecr_repository.this[0].arn : data.aws_ecr_repository.existing[0].arn
  repository_url  = var.create_repository ? aws_ecr_repository.this[0].repository_url : data.aws_ecr_repository.existing[0].repository_url
  repository_name = var.create_repository ? aws_ecr_repository.this[0].name : data.aws_ecr_repository.existing[0].name
}

output "repository_arn" {
  description = "ECR repository ARN."
  value       = local.repository_arn
}

output "repository_url" {
  description = "ECR repository URL."
  value       = local.repository_url
}

output "repository_name" {
  description = "ECR repository name."
  value       = local.repository_name
}

output "registry_url" {
  description = "ECR registry host."
  value       = split("/", local.repository_url)[0]
}
