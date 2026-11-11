variable "aws_region" {
  description = "AWS region for the Terraform state S3 bucket."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project prefix for default state bucket naming and tags."
  type        = string
  default     = "devops-stack"
}

variable "state_bucket_name" {
  description = "Optional custom S3 bucket name for Terraform state."
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "Allow destroying a non-empty state bucket during cleanup."
  type        = bool
  default     = true
}
