output "role_arn" {
  description = "IAM Role ARN for GitHub Actions OIDC authentication."
  value       = aws_iam_role.deploy.arn
}
