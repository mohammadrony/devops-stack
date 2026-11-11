variable "name_prefix" {
  description = "Prefix applied to IAM resources."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) allowed to assume the deploy role from main."
  type        = string
}

variable "github_oidc_subject" {
  description = "Optional full OIDC sub claim override matching GitHub immutable subject IDs."
  type        = string
  default     = null
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN allowed for push and pull."
  type        = string
}

variable "ec2_instance_arn" {
  description = "Target EC2 instance ARN for SSM deployments."
  type        = string
}
