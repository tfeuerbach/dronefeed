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
  description = "Allocate and associate an Elastic IP (needed for stable MEDIA_IP / DNS / ACME)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
