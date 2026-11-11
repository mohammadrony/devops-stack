output "environment" {
  description = "Provisioned environment name."
  value       = var.environment
}

output "aws_region" {
  description = "AWS region for GitHub Actions AWS_REGION variable."
  value       = var.aws_region
}

output "ec2_instance_id" {
  description = "EC2 instance ID for GitHub Actions EC2_INSTANCE_ID variable."
  value       = module.compute.instance_id
}

output "ec2_public_ip" {
  description = "Public IPv4 address of the application instance."
  value       = module.compute.public_ip
}

output "app_url" {
  description = "Base HTTP URL of the deployed service."
  value       = "http://${module.compute.public_ip}:8080"
}

output "ecr_repository_name" {
  description = "ECR repository name for GitHub Actions ECR_REPOSITORY variable."
  value       = module.registry.repository_name
}

output "ecr_repository_url" {
  description = "Full ECR repository URL."
  value       = module.registry.repository_url
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group receiving container logs."
  value       = module.compute.cloudwatch_log_group
}

output "github_actions_role_arn" {
  description = "IAM Role ARN for GitHub Actions AWS_ROLE_ARN secret."
  value       = module.github_oidc.role_arn
}
