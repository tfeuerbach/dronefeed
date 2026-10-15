output "vpc_id" {
  description = "Dedicated VPC ID."
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "Public subnet ID."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Application security group ID."
  value       = aws_security_group.app.id
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "instance_private_ip" {
  description = "Private IPv4."
  value       = var.associate_elastic_ip ? aws_network_interface.app[0].private_ip : aws_instance.app.private_ip
}

output "public_ip" {
  description = "Public IPv4 (Elastic IP when enabled)."
  value       = var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "app_url" {
  description = "Browser URL (plain HTTP — no TLS on IP-first installs)."
  value       = "http://${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "admin_email" {
  description = "Bootstrap admin email (password is in secrets.auto.tfvars / setup.sh output only)."
  value       = var.admin_email
}

output "deploy_user" {
  description = "Linux user for SSH / compose."
  value       = var.deploy_user
}

output "name_prefix" {
  description = "Resource name prefix (used by wake.sh schedule names)."
  value       = var.name_prefix
}

output "aws_region" {
  description = "AWS region for this stack."
  value       = var.aws_region
}

output "ssh_hint" {
  description = "Example SSH command (replace -i path with your private key)."
  value       = "ssh -i <private-key> ${var.deploy_user}@${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "scheduler_role_arn" {
  description = "EventBridge Scheduler role ARN (null if weekday schedule disabled)."
  value       = var.enable_business_hours_schedule ? aws_iam_role.scheduler[0].arn : null
}

output "schedule_start_name" {
  description = "Weekday start schedule name (null if disabled)."
  value       = var.enable_business_hours_schedule ? aws_scheduler_schedule.ec2_start[0].name : null
}

output "schedule_stop_name" {
  description = "Weekday stop schedule name (null if disabled)."
  value       = var.enable_business_hours_schedule ? aws_scheduler_schedule.ec2_stop[0].name : null
}

output "next_steps" {
  description = "Post-apply checklist (IP-first HTTP; DNS-only handoff when app_hostname is set)."
  value       = <<-EOT
    Public IP: ${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
    App URL:   http://${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
    Admin:     ${var.admin_email}
    SSH:       ssh -i <private-key> ${var.deploy_user}@${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}

    1. Wait a few minutes for first-boot Docker build (cloud-init + compose).
    2. Open the App URL (plain HTTP — not HTTPS) and log in with the admin password from setup.sh.
    3. After-hours test window: ./wake.sh 4|8|12|24
    ${local.ui_edge_enabled ? "\nUI hostname: ${trimspace(var.app_hostname)}\nDNS ticket (other account):\n  1) Add ACM validation CNAMEs from: terraform output ui_acm_validation_records\n  2) After cert Issued: set enable_ui_cloudfront=true and terraform apply\n  3) Alias A/AAAA ${trimspace(var.app_hostname)} → UI CloudFront domain (terraform output ui_cloudfront_domain)\n  4) On box: PHX_HOST=${trimspace(var.app_hostname)} PHX_SCHEME=https CADDYFILE=Caddyfile.http" : "\nOptional later: set app_hostname + apply for Spectre ACM/Lambda@Edge; DNS account only adds validation + alias (see README Path 2)."}
    ${var.enable_maintenance_static ? "\nOffline page preview: https://${aws_cloudfront_distribution.maintenance[0].domain_name}/index.html" : ""}
    ${var.enable_business_hours_schedule ? "\nBusiness hours: auto-start ${var.schedule_start_hour}:00 / stop ${var.schedule_stop_hour}:00 ${var.schedule_timezone} Mon–Fri." : ""}
    ${var.enable_ops_alerts ? "\nOps email: ${var.ops_alert_email} (Confirm SNS subscription). Budget ${var.monthly_budget_usd} USD/mo; disk>=${var.disk_alarm_percent}% swap>=${var.swap_alarm_percent}% + OOM." : ""}

    Console: CloudWatch dashboard ${aws_cloudwatch_dashboard.ops.dashboard_name}
    Logs:    /${var.name_prefix}/{web,caddy,mediamtx,db,bootstrap,system}
  EOT
}

output "schedule_timezone" {
  description = "IANA timezone for weekday start/stop (null if schedule disabled)."
  value       = var.enable_business_hours_schedule ? var.schedule_timezone : null
}

output "schedule_start_hour" {
  description = "Weekday start hour 0–23 local (null if schedule disabled)."
  value       = var.enable_business_hours_schedule ? var.schedule_start_hour : null
}

output "schedule_stop_hour" {
  description = "Weekday stop hour 0–23 local (null if schedule disabled)."
  value       = var.enable_business_hours_schedule ? var.schedule_stop_hour : null
}

output "business_hours_schedule" {
  description = "Weekday auto start/stop summary (null if disabled)."
  value = var.enable_business_hours_schedule ? {
    timezone           = var.schedule_timezone
    start_hour         = var.schedule_start_hour
    stop_hour          = var.schedule_stop_hour
    start_cron         = "Mon–Fri ${var.schedule_start_hour}:00"
    stop_cron          = "Mon–Fri ${var.schedule_stop_hour}:00"
    start_name         = aws_scheduler_schedule.ec2_start[0].name
    stop_name          = aws_scheduler_schedule.ec2_stop[0].name
    scheduler_role_arn = aws_iam_role.scheduler[0].arn
  } : null
}

output "maintenance_bucket" {
  description = "After-hours S3 bucket name (null if disabled)."
  value       = var.enable_maintenance_static ? local.maintenance_bucket_id : null
}

output "maintenance_bucket_same_account" {
  description = "Whether the offline-page bucket uses the primary account credentials."
  value       = var.enable_maintenance_static ? var.maintenance_bucket_same_account : null
}

output "maintenance_distribution_id" {
  description = "CloudFront distribution ID for the after-hours page (null if disabled)."
  value       = var.enable_maintenance_static ? aws_cloudfront_distribution.maintenance[0].id : null
}

output "maintenance_cloudfront_domain" {
  description = "CloudFront domain for the after-hours page (null if disabled)."
  value       = var.enable_maintenance_static ? aws_cloudfront_distribution.maintenance[0].domain_name : null
}

output "maintenance_url" {
  description = "HTTPS URL of the seeded after-hours index.html (null if disabled)."
  value       = var.enable_maintenance_static ? "https://${aws_cloudfront_distribution.maintenance[0].domain_name}/index.html" : null
}

output "ops_alerts_enabled" {
  description = "Whether SNS ops email alerts are enabled."
  value       = var.enable_ops_alerts
}

output "ops_alerts_topic_arn" {
  description = "SNS topic ARN for ops alerts (null if disabled)."
  value       = var.enable_ops_alerts ? aws_sns_topic.ops_alerts[0].arn : null
}

output "ops_alert_email" {
  description = "Operator email subscribed to ops alerts (null if disabled)."
  value       = var.enable_ops_alerts ? var.ops_alert_email : null
}

output "ops_dashboard_name" {
  description = "CloudWatch dashboard name for EC2 / network / container logs."
  value       = aws_cloudwatch_dashboard.ops.dashboard_name
}

output "ops_log_group_prefix" {
  description = "CloudWatch Logs prefix for Compose services (/{name_prefix}/…)."
  value       = "/${var.name_prefix}"
}

output "app_hostname" {
  description = "Configured UI hostname (empty if IP-first only)."
  value       = local.ui_edge_enabled ? trimspace(var.app_hostname) : null
}

output "ui_acm_certificate_arn" {
  description = "ACM cert ARN for the UI hostname (null if app_hostname unset)."
  value       = local.ui_edge_enabled ? aws_acm_certificate.ui[0].arn : null
}

output "ui_acm_validation_records" {
  description = "DNS records the hosted-zone owner must create for ACM validation."
  value = local.ui_edge_enabled ? [
    for dvo in aws_acm_certificate.ui[0].domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ] : []
}

output "ui_edge_lambda_qualified_arn" {
  description = "Published Lambda@Edge version ARN (null if app_hostname unset)."
  value       = local.ui_edge_enabled ? aws_lambda_function.ui_edge[0].qualified_arn : null
}

output "ui_cloudfront_domain" {
  description = "UI CloudFront domain name for the Route 53 alias (null until enable_ui_cloudfront)."
  value       = local.ui_cloudfront_enabled ? aws_cloudfront_distribution.ui[0].domain_name : null
}

output "ui_cloudfront_distribution_id" {
  description = "UI CloudFront distribution ID (null until enable_ui_cloudfront)."
  value       = local.ui_cloudfront_enabled ? aws_cloudfront_distribution.ui[0].id : null
}

output "ui_cloudfront_enabled" {
  description = "Whether the UI CloudFront distribution is managed by this stack."
  value       = local.ui_cloudfront_enabled
}
