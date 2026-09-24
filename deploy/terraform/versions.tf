terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project   = "dronefeed"
        ManagedBy = "terraform"
      },
      var.tags
    )
  }
}

# S3 for the offline page — same account (default creds) or cross-account keys.
provider "aws" {
  alias  = "maintenance"
  region = var.maintenance_bucket_region != "" ? var.maintenance_bucket_region : var.aws_region

  access_key = var.maintenance_bucket_same_account ? null : var.maintenance_bucket_access_key
  secret_key = var.maintenance_bucket_same_account ? null : var.maintenance_bucket_secret_key
  token      = var.maintenance_bucket_same_account || var.maintenance_bucket_session_token == "" ? null : var.maintenance_bucket_session_token
}
