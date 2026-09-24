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

output "ssh_hint" {
  description = "Example SSH command (replace key path / user as needed)."
  value       = "ssh -i <key.pem> ${var.deploy_user}@${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "next_steps" {
  description = "Post-apply checklist (IP-first HTTP; domain/DNS optional later)."
  value       = <<-EOT
    Public IP: ${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}

    1. Wait a few minutes for first-boot Docker build (cloud-init + compose).
    2. Open http://<public_ip> in a browser (plain HTTP — not HTTPS).
    3. Log in with credentials from /opt/drone-feed/DEPLOY.txt on the instance
       (SSH/SSM: cat /opt/drone-feed/DEPLOY.txt).

    Optional later: point a domain A record at the Elastic IP, set PHX_HOST/MEDIA_HOST,
    CADDYFILE=Caddyfile, PHX_SCHEME=https, ACME_EMAIL=you@example.com, then recreate caddy.
    ${var.enable_maintenance_static ? "\nAfter-hours page: ${aws_cloudfront_distribution.maintenance[0].domain_name}/index.html\n  (Terraform wrote deploy/maintenance/generated/aws.env when using setup.sh — or copy terraform outputs.)\n  Cloudflare Worker still needed for failover; see deploy/maintenance/README.md." : ""}
    ${var.enable_business_hours_schedule ? "\nBusiness hours: auto-start ${var.schedule_start_hour}:00 / stop ${var.schedule_stop_hour}:00 ${var.schedule_timezone} Mon–Fri." : ""}
  EOT
}

output "business_hours_schedule" {
  description = "Weekday auto start/stop summary (null if disabled)."
  value = var.enable_business_hours_schedule ? {
    timezone   = var.schedule_timezone
    start_cron = "Mon–Fri ${var.schedule_start_hour}:00"
    stop_cron  = "Mon–Fri ${var.schedule_stop_hour}:00"
    start_name = aws_scheduler_schedule.ec2_start[0].name
    stop_name  = aws_scheduler_schedule.ec2_stop[0].name
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
