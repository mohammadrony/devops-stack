locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "registry" {
  source = "./modules/registry"

  repository_name       = var.project_name
  create_repository     = var.create_ecr_repository
  force_delete          = var.environment != "production"
  image_retention_count = var.environment == "production" ? 20 : 10
}

module "compute" {
  source = "./modules/compute"

  name_prefix                   = local.name_prefix
  environment                   = var.environment
  instance_type                 = var.instance_type
  app_image_tag                 = var.app_image_tag
  log_retention_days            = var.log_retention_days
  allowed_cidr                  = var.allowed_cidr
  enable_termination_protection = var.enable_termination_protection
  ecr_repository_arn            = module.registry.repository_arn
  ecr_repository_url            = module.registry.repository_url
  ecr_registry_url              = module.registry.registry_url
}

module "github_oidc" {
  source = "./modules/github_oidc"

  name_prefix          = local.name_prefix
  github_repository    = var.github_repository
  github_oidc_subject  = var.github_oidc_subject
  create_oidc_provider = var.create_oidc_provider
  ecr_repository_arn   = module.registry.repository_arn
  ec2_instance_arn     = module.compute.instance_arn
}
