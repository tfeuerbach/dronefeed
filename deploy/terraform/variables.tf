variable "aws_region" {
  description = "AWS region (prod reference deploy is us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "dronefeed"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type. Defaults match current production (≤4 public feeds @720p).
    Use c7i.4xlarge or larger for >4 concurrent public feeds or several @1080p.
  EOT
  type        = string
  default     = "c7i.2xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS gp3 size in GiB (80–200 recommended for ~5-day retention)."
  type        = number
  default     = 80
}

variable "availability_zone" {
  description = "AZ for the public subnet. Empty = first AZ in the region."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (must be inside vpc_cidr)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to SSH (port 22). Prefer your office/VPN CIDR over 0.0.0.0/0."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "media_ingress_cidrs" {
  description = "CIDRs allowed for browser + media ports (80/443/RTMP/RTSP/SRT/HLS/UDP ingest)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "Existing EC2 key pair name. Ignored when public_key is set (Terraform creates a key)."
  type        = string
  default     = ""
}

variable "public_key" {
  description = "SSH public key material (ssh-ed25519/ssh-rsa …). Creates an aws_key_pair when non-empty."
  type        = string
  default     = ""
}

variable "git_repo_url" {
  description = "Git clone URL for the DroneFeed repo on first boot."
  type        = string
  default     = "https://github.com/tfeuerbach/dronefeed.git"
}

variable "git_ref" {
  description = "Git branch or tag checked out on first boot. Must include deploy/Caddyfile.http and runtime PHX_SCHEME/force_ssl (force_ssl only when https)."
  type        = string
  default     = "master"
}

variable "deploy_user" {
  description = "Linux user that owns /opt/drone-feed and runs docker compose."
  type        = string
  default     = "dronefeed"
}

variable "enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore so you can use Session Manager without opening SSH."
  type        = bool
  default     = true
}

variable "enable_ses_send" {
  description = "Attach a minimal SES send policy (for SMTP/API mail from the instance role). Off by default — no email required for IP-first deploys."
  type        = bool
  default     = false
}

variable "admin_email" {
  description = "Bootstrap admin email written into deploy/.env on first boot."
  type        = string
  default     = "admin@dronefeed.local"
}

variable "admin_password" {
  description = "Bootstrap admin password (≥8 chars, digit + symbol). Prefer secrets.auto.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_authorized_key" {
  description = "SSH public key installed for deploy_user (dronefeed). Usually same as public_key."
  type        = string
  default     = ""
}

variable "associate_elastic_ip" {
  description = "Allocate an Elastic IP on the primary ENI before boot (required for stable IP-first HTTP)."
  type        = bool
  default     = true
}

variable "enable_maintenance_static" {
  description = "Wire CloudFront + offline page objects for after-hours (deploy/maintenance)."
  type        = bool
  default     = true
}

variable "maintenance_create_bucket" {
  description = "true = create a new S3 bucket; false = use an existing bucket named by maintenance_bucket_name."
  type        = bool
  default     = true
}

variable "maintenance_bucket_name" {
  description = "S3 bucket for the offline page. Required when maintenance_create_bucket is false; optional override when creating."
  type        = string
  default     = ""
}

variable "maintenance_bucket_same_account" {
  description = "true = bucket is in the same AWS account as EC2 (default creds). false = use maintenance_bucket_* keys."
  type        = bool
  default     = true
}

variable "maintenance_bucket_region" {
  description = "AWS region of the offline-page S3 bucket. Empty = aws_region."
  type        = string
  default     = ""
}

variable "maintenance_bucket_access_key" {
  description = "Access key for the offline-page bucket account (cross-account only). Prefer secrets.auto.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "maintenance_bucket_secret_key" {
  description = "Secret key for the offline-page bucket account (cross-account only). Prefer secrets.auto.tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "maintenance_bucket_session_token" {
  description = "Optional session token for cross-account temporary credentials."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_business_hours_schedule" {
  description = "Auto start/stop the EC2 instance on weekdays via EventBridge Scheduler (default on: 8→18 local)."
  type        = bool
  default     = true
}

variable "schedule_timezone" {
  description = "IANA timezone for the business-hours schedule (e.g. America/New_York)."
  type        = string
  default     = "America/New_York"
}

variable "schedule_start_hour" {
  description = "Local hour (0–23) to start the instance Mon–Fri when the schedule is enabled."
  type        = number
  default     = 8

  validation {
    condition     = var.schedule_start_hour >= 0 && var.schedule_start_hour <= 23
    error_message = "schedule_start_hour must be 0–23."
  }
}

variable "schedule_stop_hour" {
  description = "Local hour (0–23) to stop the instance Mon–Fri when the schedule is enabled."
  type        = number
  default     = 18

  validation {
    condition     = var.schedule_stop_hour >= 0 && var.schedule_stop_hour <= 23
    error_message = "schedule_stop_hour must be 0–23."
  }
}

variable "enable_ops_alerts" {
  description = "SNS email for schedule miss / on-too-long / monthly budget / disk+swap pressure / OOM lines, plus bootstrap mail from setup.sh."
  type        = bool
  default     = false
}

variable "disk_alarm_percent" {
  description = "CloudWatch alarm threshold for root disk_used_percent (SNS when ops alerts enabled)."
  type        = number
  default     = 85

  validation {
    condition     = var.disk_alarm_percent >= 50 && var.disk_alarm_percent <= 99
    error_message = "disk_alarm_percent must be between 50 and 99."
  }
}

variable "swap_alarm_percent" {
  description = "CloudWatch alarm threshold for swap_used_percent (memory pressure / OOM risk; SNS when ops alerts enabled)."
  type        = number
  default     = 50

  validation {
    condition     = var.swap_alarm_percent >= 10 && var.swap_alarm_percent <= 99
    error_message = "swap_alarm_percent must be between 10 and 99."
  }
}

variable "ops_alert_email" {
  description = "Operator inbox for SNS ops alerts (must Confirm the AWS subscription email once)."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_ops_alerts || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.ops_alert_email))
    error_message = "ops_alert_email must be a valid email when enable_ops_alerts is true."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget (USD). SNS notifies at 80% and 100% when ops alerts are enabled."
  type        = number
  default     = 500

  validation {
    condition     = var.monthly_budget_usd >= 1
    error_message = "monthly_budget_usd must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for Compose service log groups."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs allowed retention value."
  }
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
