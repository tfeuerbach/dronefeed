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
  description = "Post-apply checklist (IP-first HTTP; domain/DNS optional later)."
  value       = <<-EOT
    Public IP: ${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
    App URL:   http://${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
    Admin:     ${var.admin_email}
    SSH:       ssh -i <private-key> ${var.deploy_user}@${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}

    1. Wait a few minutes for first-boot Docker build (cloud-init + compose).
    2. Open the App URL (plain HTTP — not HTTPS) and log in with the admin password from setup.sh.
    3. After-hours test window: ./wake.sh 4|8|12|24

    Optional later (other account DNS): A record → EIP, then on-box Caddy HTTPS.
    Hostname offline failover: Path 1 Cloudflare or Path 2 Route 53 in README.
    ${var.enable_maintenance_static ? "\nOffline page preview: https://${aws_cloudfront_distribution.maintenance[0].domain_name}/index.html" : ""}
    ${var.enable_business_hours_schedule ? "\nBusiness hours: auto-start ${var.schedule_start_hour}:00 / stop ${var.schedule_stop_hour}:00 ${var.schedule_timezone} Mon–Fri." : ""}
  EOT
}

output "business_hours_schedule" {
  description = "Weekday auto start/stop summary (null if disabled)."
  value = var.enable_business_hours_schedule ? {
    timezone           = var.schedule_timezone
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
