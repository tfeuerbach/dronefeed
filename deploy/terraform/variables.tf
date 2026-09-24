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
  description = "Git branch or tag to check out on first boot."
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
  description = "Attach a minimal SES send policy (for SMTP/API mail from the instance role)."
  type        = bool
  default     = true
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
  description = "Auto start/stop the EC2 instance on weekdays via EventBridge Scheduler."
  type        = bool
  default     = false
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

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
