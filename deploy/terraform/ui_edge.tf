# UI edge in this account: ACM + Lambda@Edge + (optional) CloudFront.
# DNS stays in the hosted-zone account — validation CNAMEs + alias to UI CloudFront.

locals {
  ui_edge_enabled       = trimspace(var.app_hostname) != ""
  ui_cloudfront_enabled = local.ui_edge_enabled && var.enable_ui_cloudfront
  ui_origin_base = format(
    "http://%s",
    var.associate_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
  )
  ui_maintenance_url = var.enable_maintenance_static ? format(
    "https://%s/index.html",
    aws_cloudfront_distribution.maintenance[0].domain_name
  ) : ""
}

# -----------------------------------------------------------------------------
# ACM (us-east-1) — DNS validation records are for the Route 53 ticket
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "ui" {
  count = local.ui_edge_enabled ? 1 : 0

  domain_name       = trimspace(var.app_hostname)
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.name_prefix}-ui-cert"
  }
}

resource "aws_acm_certificate_validation" "ui" {
  count = local.ui_cloudfront_enabled ? 1 : 0

  certificate_arn = aws_acm_certificate.ui[0].arn

  timeouts {
    create = "45m"
  }
}

# -----------------------------------------------------------------------------
# Lambda@Edge (viewer-request) — publish a version for CloudFront
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ui_edge_assume" {
  count = local.ui_edge_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ui_edge" {
  count = local.ui_edge_enabled ? 1 : 0

  name               = "${var.name_prefix}-ui-edge"
  assume_role_policy = data.aws_iam_policy_document.ui_edge_assume[0].json

  tags = {
    Name = "${var.name_prefix}-ui-edge"
  }
}

resource "aws_iam_role_policy_attachment" "ui_edge_basic" {
  count = local.ui_edge_enabled ? 1 : 0

  role       = aws_iam_role.ui_edge[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "ui_edge" {
  count = local.ui_edge_enabled ? 1 : 0

  type        = "zip"
  output_path = "${path.module}/.build/ui_edge_viewer_request.zip"

  source {
    content = templatefile("${path.module}/workers/lambda-edge-viewer-request.js.tftpl", {
      origin_base     = local.ui_origin_base
      maintenance_url = local.ui_maintenance_url
    })
    filename = "index.js"
  }
}

resource "aws_lambda_function" "ui_edge" {
  count = local.ui_edge_enabled ? 1 : 0

  function_name = "${var.name_prefix}-ui-edge"
  role          = aws_iam_role.ui_edge[0].arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  publish       = true
  timeout       = 5
  memory_size   = 128

  filename         = data.archive_file.ui_edge[0].output_path
  source_code_hash = data.archive_file.ui_edge[0].output_base64sha256

  tags = {
    Name = "${var.name_prefix}-ui-edge"
  }

  depends_on = [aws_iam_role_policy_attachment.ui_edge_basic]
}

# -----------------------------------------------------------------------------
# UI CloudFront — origin EIP:80 + viewer-request Lambda + custom hostname
# -----------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = local.ui_cloudfront_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  count = local.ui_cloudfront_enabled ? 1 : 0
  name  = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "ui" {
  count = local.ui_cloudfront_enabled ? 1 : 0

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name_prefix} UI (EIP origin + offline Lambda@Edge)"
  aliases             = [trimspace(var.app_hostname)]
  price_class         = "PriceClass_100"
  wait_for_deployment = true

  # CloudFront rejects raw IPs as origin domain_name; use the EC2 public DNS
  # that resolves to the Elastic IP (e.g. ec2-x-x-x-x.compute-1.amazonaws.com).
  origin {
    domain_name = aws_instance.app.public_dns
    origin_id   = "ec2-http"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "ec2-http"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host[0].id

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.ui_edge[0].qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.ui[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.name_prefix}-ui"
  }

  depends_on = [aws_acm_certificate_validation.ui]
}
