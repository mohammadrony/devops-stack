variable "name_prefix" {
  description = "Prefix applied to compute resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "app_image_tag" {
  description = "Initial container image tag in ECR."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Log Group retention period in days."
  type        = number
}

variable "allowed_cidr" {
  description = "IPv4 CIDR block permitted to reach port 8080."
  type        = string
}

variable "enable_termination_protection" {
  description = "Enable EC2 API termination protection."
  type        = bool
}

variable "ecr_repository_arn" {
  description = "ECR repository ARN scoped for EC2 pulls."
  type        = string
}

variable "ecr_repository_url" {
  description = "Full ECR repository URL."
  type        = string
}

variable "ecr_registry_url" {
  description = "ECR registry host."
  type        = string
}
