environment                   = "staging"
aws_region                    = "ap-south-1"
instance_type                 = "t3.micro"
log_retention_days            = 7
enable_termination_protection = false
github_oidc_subject           = "repo:mohammadrony@71396772/devops-stack@1453322379:ref:refs/heads/main"
create_oidc_provider          = true
create_ecr_repository         = true
