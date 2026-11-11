variable "aws_region" {
  description = "AWS region to deploy resources into."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project prefix used in resource names and tags."
  type        = string
  default     = "devops-stack"
}

variable "environment" {
  description = "Deployment environment (staging or production)."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be either staging or production."
  }
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "app_image_tag" {
  description = "Initial container image tag in ECR to run on boot."
  type        = string
  default     = "0.1.0"
}

variable "log_retention_days" {
  description = "CloudWatch Log Group retention period in days."
  type        = number
  default     = 7
}

variable "allowed_cidr" {
  description = "IPv4 CIDR block permitted to reach port 8080."
  type        = string
  default     = "0.0.0.0/0"
}

variable "enable_termination_protection" {
  description = "Enable EC2 API termination protection."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) allowed to assume the OIDC deploy role from main."
  type        = string
  default     = "mohammadrony/devops-stack"
}

variable "github_oidc_subject" {
  description = "Full OIDC sub claim override when GitHub immutable subject IDs are enabled."
  type        = string
  default     = null
}

variable "create_oidc_provider" {
  description = "Create the account-level GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "create_ecr_repository" {
  description = "Create the ECR repository in this environment."
  type        = bool
  default     = true
}
