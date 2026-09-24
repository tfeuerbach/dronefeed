# -----------------------------------------------------------------------------
# After-hours static page — S3 (this or another account) + CloudFront (OAC)
# S3 ops use the aws.maintenance provider (same creds or cross-account keys).
# CloudFront always lives in the primary EC2 account.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = var.enable_maintenance_static ? 1 : 0
  name  = "Managed-CachingOptimized"
}

locals {
  maintenance_create = var.enable_maintenance_static && var.maintenance_create_bucket

  maintenance_bucket_name = coalesce(
    var.maintenance_bucket_name != "" ? var.maintenance_bucket_name : null,
    var.enable_maintenance_static ? "${var.name_prefix}-after-hours-${data.aws_caller_identity.current.account_id}" : null
  )

  maintenance_bucket_id = (
    !var.enable_maintenance_static ? "" :
    local.maintenance_create ? aws_s3_bucket.maintenance[0].id : data.aws_s3_bucket.maintenance[0].id
  )

  maintenance_bucket_arn = (
    !var.enable_maintenance_static ? "" :
    local.maintenance_create ? aws_s3_bucket.maintenance[0].arn : data.aws_s3_bucket.maintenance[0].arn
  )

  maintenance_bucket_regional_domain = (
    !var.enable_maintenance_static ? "" :
    local.maintenance_create ? aws_s3_bucket.maintenance[0].bucket_regional_domain_name : data.aws_s3_bucket.maintenance[0].bucket_regional_domain_name
  )

  maintenance_asset_base = (
    length(aws_cloudfront_distribution.maintenance) > 0
    ? "https://${aws_cloudfront_distribution.maintenance[0].domain_name}"
    : ""
  )

  maintenance_index_html = (
    var.enable_maintenance_static
    ? replace(
      replace(
        replace(
          replace(
            replace(
              replace(
                replace(
                  file("${path.module}/../maintenance/templates/index.html"),
                  "{{PAGE_TITLE}}",
                  "DroneFeed is down after hours"
                ),
                "{{ASSET_BASE_URL}}",
                local.maintenance_asset_base
              ),
              "{{BRAND_NAME}}",
              "DroneFeed"
            ),
            "{{PAGE_EYEBROW}}",
            "Service offline"
          ),
          "{{PAGE_HEADLINE}}",
          "DroneFeed is down after hours"
        ),
        "{{PAGE_LEDE}}",
        "The app server is powered off to save cost. Feeds, uploads, and pull URLs will be back when the host is started again."
      ),
      "{{PAGE_META}}",
      "<strong>HTTP UI only.</strong> SRT / RTSP / RTMP ingest and pull stay unreachable until the instance is running."
    )
    : ""
  )
}

check "maintenance_bucket_name" {
  assert {
    condition     = !var.enable_maintenance_static || local.maintenance_bucket_name != null && local.maintenance_bucket_name != ""
    error_message = "maintenance_bucket_name is required when enable_maintenance_static is true (or leave empty only when creating a new bucket)."
  }
}

check "maintenance_cross_account_keys" {
  assert {
    condition = (
      !var.enable_maintenance_static ||
      var.maintenance_bucket_same_account ||
      (var.maintenance_bucket_access_key != "" && var.maintenance_bucket_secret_key != "")
    )
    error_message = "Cross-account maintenance bucket requires maintenance_bucket_access_key and maintenance_bucket_secret_key."
  }
}

check "maintenance_existing_name" {
  assert {
    condition = (
      !var.enable_maintenance_static ||
      var.maintenance_create_bucket ||
      var.maintenance_bucket_name != ""
    )
    error_message = "Set maintenance_bucket_name when using an existing offline-page bucket (maintenance_create_bucket = false)."
  }
}

# Existing bucket (same or cross-account via aws.maintenance provider).
data "aws_s3_bucket" "maintenance" {
  count    = var.enable_maintenance_static && !var.maintenance_create_bucket ? 1 : 0
  provider = aws.maintenance
  bucket   = var.maintenance_bucket_name
}

resource "aws_s3_bucket" "maintenance" {
  count    = local.maintenance_create ? 1 : 0
  provider = aws.maintenance
  bucket   = local.maintenance_bucket_name

  tags = {
    Name = "${var.name_prefix}-after-hours"
  }
}

resource "aws_s3_bucket_public_access_block" "maintenance" {
  count    = local.maintenance_create ? 1 : 0
  provider = aws.maintenance
  bucket   = aws_s3_bucket.maintenance[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "maintenance" {
  count    = local.maintenance_create ? 1 : 0
  provider = aws.maintenance
  bucket   = aws_s3_bucket.maintenance[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "maintenance" {
  count    = local.maintenance_create ? 1 : 0
  provider = aws.maintenance
  bucket   = aws_s3_bucket.maintenance[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_cloudfront_origin_access_control" "maintenance" {
  count = var.enable_maintenance_static ? 1 : 0

  name                              = "${var.name_prefix}-maintenance-oac"
  description                       = "OAC for ${var.name_prefix} after-hours static page"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "maintenance" {
  count = var.enable_maintenance_static ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name_prefix} after-hours maintenance page"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  wait_for_deployment = true

  origin {
    domain_name              = local.maintenance_bucket_regional_domain
    origin_id                = "s3-maintenance"
    origin_access_control_id = aws_cloudfront_origin_access_control.maintenance[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-maintenance"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.name_prefix}-after-hours"
  }

  depends_on = [aws_s3_bucket_public_access_block.maintenance]
}

data "aws_iam_policy_document" "maintenance_s3" {
  count = var.enable_maintenance_static ? 1 : 0

  statement {
    sid    = "AllowCloudFrontServicePrincipalRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${local.maintenance_bucket_arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.maintenance[0].arn]
    }
  }
}

# Replaces the bucket policy on the target bucket (required for CloudFront OAC).
resource "aws_s3_bucket_policy" "maintenance" {
  count    = var.enable_maintenance_static ? 1 : 0
  provider = aws.maintenance
  bucket   = local.maintenance_bucket_id
  policy   = data.aws_iam_policy_document.maintenance_s3[0].json

  depends_on = [
    aws_s3_bucket_public_access_block.maintenance,
    aws_cloudfront_distribution.maintenance,
  ]
}

resource "aws_s3_object" "maintenance_index" {
  count    = var.enable_maintenance_static ? 1 : 0
  provider = aws.maintenance

  bucket        = local.maintenance_bucket_id
  key           = "index.html"
  content       = local.maintenance_index_html
  content_type  = "text/html; charset=utf-8"
  cache_control = "public, max-age=60"
  etag          = md5(local.maintenance_index_html)

  depends_on = [aws_s3_bucket_policy.maintenance]
}

resource "aws_s3_object" "maintenance_brand" {
  count    = var.enable_maintenance_static ? 1 : 0
  provider = aws.maintenance

  bucket        = local.maintenance_bucket_id
  key           = "brand-mark.svg"
  source        = "${path.module}/../maintenance/brand-mark.svg"
  content_type  = "image/svg+xml"
  cache_control = "public, max-age=86400"
  etag          = filemd5("${path.module}/../maintenance/brand-mark.svg")

  depends_on = [aws_s3_bucket_policy.maintenance]
}
