locals {
  az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  key_name = var.public_key != "" ? aws_key_pair.deploy[0].key_name : var.key_name

  # Mirrors deploy/README.md security group table.
  tcp_media_ports = [
    { port = 80, description = "Caddy HTTP (ACME + redirect)" },
    { port = 443, description = "Caddy HTTPS" },
    { port = 1935, description = "MediaMTX RTMP" },
    { port = 8554, description = "MediaMTX RTSP" },
    { port = 8888, description = "MediaMTX HLS (optional direct)" },
  ]

  udp_media_ports = [
    { port = 443, description = "Caddy HTTPS HTTP/3" },
    { port = 8890, description = "MediaMTX SRT" },
  ]
}

check "access_path" {
  assert {
    condition     = var.public_key != "" || var.key_name != "" || var.enable_ssm
    error_message = "Provide public_key, key_name, or enable_ssm=true so you can reach the instance."
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Prefer the AWS-maintained "latest AL2023" pointer over a broad AMI name glob.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_key_pair" "deploy" {
  count = var.public_key != "" ? 1 : 0

  key_name   = "${var.name_prefix}-deploy"
  public_key = var.public_key
}

# -----------------------------------------------------------------------------
# Network — dedicated public VPC (matches a clean single-AZ prod layout)
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group — compose-published ports (no ALB; protocols hit the instance)
# -----------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "DroneFeed browser UI + MediaMTX ingest/pull"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_ingress_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "tcp_media" {
  for_each = {
    for pair in setproduct(local.tcp_media_ports, var.media_ingress_cidrs) :
    "${pair[0].port}-${replace(pair[1], "/", "_")}" => {
      port        = pair[0].port
      description = pair[0].description
      cidr        = pair[1]
    }
  }

  security_group_id = aws_security_group.app.id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_ingress_rule" "udp_media" {
  for_each = {
    for pair in setproduct(local.udp_media_ports, var.media_ingress_cidrs) :
    "${pair[0].port}-${replace(pair[1], "/", "_")}" => {
      port        = pair[0].port
      description = pair[0].description
      cidr        = pair[1]
    }
  }

  security_group_id = aws_security_group.app.id
  description       = each.value.description
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

# Live drone / encoder MPEG-TS UDP ingest (one port per live session).
resource "aws_vpc_security_group_ingress_rule" "udp_ingest" {
  for_each = toset(var.media_ingress_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "MediaMTX MPEG-TS UDP ingest"
  ip_protocol       = "udp"
  from_port         = 8900
  to_port           = 8999
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "All egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# IAM — SSM (ops) + optional SES (outbound mail)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.enable_ssm ? 1 : 0

  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ses_send" {
  count = var.enable_ses_send ? 1 : 0

  statement {
    sid       = "SesSend"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ses_send" {
  count = var.enable_ses_send ? 1 : 0

  name   = "${var.name_prefix}-ses-send"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ses_send[0].json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# IAM profiles can take a few seconds to become usable on new roles.
resource "time_sleep" "iam_propagation" {
  depends_on = [
    aws_iam_instance_profile.ec2,
    aws_iam_role_policy_attachment.ssm,
    aws_iam_role_policy.ses_send,
  ]

  create_duration = "15s"
}

# -----------------------------------------------------------------------------
# ENI + Elastic IP (EIP on ENI before boot so IMDS public-ipv4 is stable)
# -----------------------------------------------------------------------------

resource "aws_network_interface" "app" {
  count = var.associate_elastic_ip ? 1 : 0

  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.app.id]

  tags = {
    Name = "${var.name_prefix}-eni"
  }
}

resource "aws_eip" "app" {
  count  = var.associate_elastic_ip ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-eip"
  }
}

resource "aws_eip_association" "app" {
  count = var.associate_elastic_ip ? 1 : 0

  allocation_id        = aws_eip.app[0].id
  network_interface_id = aws_network_interface.app[0].id
}

# -----------------------------------------------------------------------------
# EC2
# -----------------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                  = data.aws_ssm_parameter.al2023_ami.value
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ec2.name
  key_name             = local.key_name != "" ? local.key_name : null

  # EIP path: attach primary ENI that already has the Elastic IP.
  # Non-EIP path: classic subnet launch with auto-assigned public IP.
  subnet_id                   = var.associate_elastic_ip ? null : aws_subnet.public.id
  vpc_security_group_ids      = var.associate_elastic_ip ? null : [aws_security_group.app.id]
  associate_public_ip_address = var.associate_elastic_ip ? null : true

  dynamic "network_interface" {
    for_each = var.associate_elastic_ip ? [1] : []
    content {
      network_interface_id = aws_network_interface.app[0].id
      device_index         = 0
    }
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    git_repo_url = var.git_repo_url
    git_ref      = var.git_ref
    deploy_user  = var.deploy_user
    name_prefix  = var.name_prefix
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  depends_on = [
    time_sleep.iam_propagation,
    aws_eip_association.app,
  ]

  tags = {
    Name = "${var.name_prefix}-app"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
