output "app_url" {
  description = "Open this in a browser."
  value       = local.use_domain ? "https://${local.app_fqdn}" : "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "alb_dns_name" {
  description = "Direct ALB address: answers 403 on purpose (traffic must come through CloudFront)."
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "session_manager_hint" {
  description = "Open a shell on an instance without SSH."
  value       = "aws ssm start-session --region ${var.region} --target $(aws ec2 describe-instances --region ${var.region} --filters Name=tag:aws:autoscaling:groupName,Values=${aws_autoscaling_group.app.name} Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text)"
}
