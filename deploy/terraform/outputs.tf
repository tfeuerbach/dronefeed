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
  value       = aws_instance.app.private_ip
}

output "public_ip" {
  description = "Stable public IPv4 (Elastic IP when enabled, else instance public IP)."
  value       = var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "ssh_hint" {
  description = "Example SSH command (replace key path / user as needed)."
  value       = "ssh -i <key.pem> ${var.deploy_user}@${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "next_steps" {
  description = "Post-apply checklist."
  value       = <<-EOT
    1. DNS: create A record PHX_HOST → ${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
    2. SSH/SSM into the host and edit /opt/drone-feed/deploy/.env
       - MEDIA_IP=${var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}
       - PHX_HOST / MEDIA_HOST / ACME_EMAIL / SECRET_KEY_BASE / POSTGRES_PASSWORD
       - ADMIN_EMAIL / ADMIN_PASSWORD / SMTP_* as needed
    3. cd /opt/drone-feed/deploy && docker compose --env-file .env up -d --build
    4. Open https://PHX_HOST and complete bootstrap login
  EOT
}
