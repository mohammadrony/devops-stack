output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "instance_arn" {
  description = "EC2 instance ARN."
  value       = aws_instance.app.arn
}

output "public_ip" {
  description = "Public IPv4 address of the EC2 instance."
  value       = aws_instance.app.public_ip
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group name."
  value       = aws_cloudwatch_log_group.app.name
}
