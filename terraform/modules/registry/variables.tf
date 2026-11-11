variable "repository_name" {
  description = "ECR repository name."
  type        = string
}

variable "create_repository" {
  description = "Create a new ECR repository rather than reading an existing one."
  type        = bool
  default     = true
}

variable "force_delete" {
  description = "Allow deleting the ECR repository when images exist."
  type        = bool
  default     = true
}

variable "image_retention_count" {
  description = "Maximum number of images retained in ECR."
  type        = number
  default     = 10
}
