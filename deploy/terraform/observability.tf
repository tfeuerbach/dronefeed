# Ops alerts (SNS email), schedule miss / on-too-long checks, monthly budget,
# CloudWatch log groups + dashboard. Container log shipping is via Docker awslogs
# + CloudWatch Agent (mem/disk) on the instance — see user_data.sh.tftpl.

locals {
  ops_alerts_enabled      = var.enable_ops_alerts
  schedule_checks_enabled = var.enable_ops_alerts && var.enable_business_hours_schedule
  log_services            = ["web", "caddy", "mediamtx", "db", "bootstrap", "system"]
  # Check 15 minutes after scheduled start/stop.
  schedule_check_minute = 15
}

# -----------------------------------------------------------------------------
# SNS + budget (email)
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "ops_alerts" {
  count = local.ops_alerts_enabled ? 1 : 0

  name = "${var.name_prefix}-ops-alerts"

  tags = {
    Name = "${var.name_prefix}-ops-alerts"
  }
}

resource "aws_sns_topic_subscription" "ops_alerts_email" {
  count = local.ops_alerts_enabled ? 1 : 0

  topic_arn = aws_sns_topic.ops_alerts[0].arn
  protocol  = "email"
  endpoint  = var.ops_alert_email
}

data "aws_iam_policy_document" "ops_alerts_sns" {
  count = local.ops_alerts_enabled ? 1 : 0

  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.ops_alerts[0].arn]
  }

  statement {
    sid    = "AllowOwnerPublish"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "SNS:Publish",
      "SNS:Subscribe",
      "SNS:Receive",
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:DeleteTopic",
    ]
    resources = [aws_sns_topic.ops_alerts[0].arn]
  }
}

resource "aws_sns_topic_policy" "ops_alerts" {
  count = local.ops_alerts_enabled ? 1 : 0

  arn    = aws_sns_topic.ops_alerts[0].arn
  policy = data.aws_iam_policy_document.ops_alerts_sns[0].json
}

resource "aws_budgets_budget" "monthly" {
  count = local.ops_alerts_enabled ? 1 : 0

  name              = "${var.name_prefix}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.ops_alerts[0].arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.ops_alerts[0].arn]
  }

  depends_on = [aws_sns_topic_policy.ops_alerts]
}

# -----------------------------------------------------------------------------
# Schedule miss / on-too-long (Lambda + EventBridge Scheduler)
# -----------------------------------------------------------------------------

data "archive_file" "schedule_check" {
  count = local.schedule_checks_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/schedule_check.py"
  output_path = "${path.module}/.build/schedule_check.zip"
}

data "aws_iam_policy_document" "schedule_check_assume" {
  count = local.schedule_checks_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "schedule_check" {
  count = local.schedule_checks_enabled ? 1 : 0

  name               = "${var.name_prefix}-schedule-check"
  assume_role_policy = data.aws_iam_policy_document.schedule_check_assume[0].json

  tags = {
    Name = "${var.name_prefix}-schedule-check"
  }
}

data "aws_iam_policy_document" "schedule_check" {
  count = local.schedule_checks_enabled ? 1 : 0

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }

  statement {
    sid       = "DescribeInstance"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishAlert"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.ops_alerts[0].arn]
  }
}

resource "aws_iam_role_policy" "schedule_check" {
  count = local.schedule_checks_enabled ? 1 : 0

  name   = "${var.name_prefix}-schedule-check"
  role   = aws_iam_role.schedule_check[0].id
  policy = data.aws_iam_policy_document.schedule_check[0].json
}

resource "aws_lambda_function" "schedule_check" {
  count = local.schedule_checks_enabled ? 1 : 0

  function_name    = "${var.name_prefix}-schedule-check"
  role             = aws_iam_role.schedule_check[0].arn
  handler          = "schedule_check.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.schedule_check[0].output_path
  source_code_hash = data.archive_file.schedule_check[0].output_base64sha256

  environment {
    variables = {
      INSTANCE_ID   = aws_instance.app.id
      SNS_TOPIC_ARN = aws_sns_topic.ops_alerts[0].arn
      NAME_PREFIX   = var.name_prefix
    }
  }

  tags = {
    Name = "${var.name_prefix}-schedule-check"
  }

  depends_on = [aws_iam_role_policy.schedule_check]
}

data "aws_iam_policy_document" "schedule_check_invoke_assume" {
  count = local.schedule_checks_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "schedule_check_invoke" {
  count = local.schedule_checks_enabled ? 1 : 0

  name               = "${var.name_prefix}-schedule-check-invoke"
  assume_role_policy = data.aws_iam_policy_document.schedule_check_invoke_assume[0].json

  tags = {
    Name = "${var.name_prefix}-schedule-check-invoke"
  }
}

data "aws_iam_policy_document" "schedule_check_invoke" {
  count = local.schedule_checks_enabled ? 1 : 0

  statement {
    sid       = "Invoke"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.schedule_check[0].arn]
  }
}

resource "aws_iam_role_policy" "schedule_check_invoke" {
  count = local.schedule_checks_enabled ? 1 : 0

  name   = "${var.name_prefix}-schedule-check-invoke"
  role   = aws_iam_role.schedule_check_invoke[0].id
  policy = data.aws_iam_policy_document.schedule_check_invoke[0].json
}

resource "aws_scheduler_schedule" "check_started" {
  count = local.schedule_checks_enabled ? 1 : 0

  name       = "${var.name_prefix}-check-started"
  group_name = "default"
  state      = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(${local.schedule_check_minute} ${var.schedule_start_hour} ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  description                  = "Alert if EC2 is not running after weekday start"

  target {
    arn      = aws_lambda_function.schedule_check[0].arn
    role_arn = aws_iam_role.schedule_check_invoke[0].arn
    input    = jsonencode({ expect = "running" })
  }
}

resource "aws_scheduler_schedule" "check_stopped" {
  count = local.schedule_checks_enabled ? 1 : 0

  name       = "${var.name_prefix}-check-stopped"
  group_name = "default"
  state      = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(${local.schedule_check_minute} ${var.schedule_stop_hour} ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  description                  = "Alert if EC2 is still running after weekday stop"

  target {
    arn      = aws_lambda_function.schedule_check[0].arn
    role_arn = aws_iam_role.schedule_check_invoke[0].arn
    input    = jsonencode({ expect = "stopped" })
  }
}

# -----------------------------------------------------------------------------
# CloudWatch log groups (Docker awslogs + bootstrap + system/OOM)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(local.log_services)

  name              = "/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.name_prefix}-${each.key}-logs"
  }
}

# OOM killer / memory pressure lines from /var/log/messages → custom metric → SNS.
resource "aws_cloudwatch_log_metric_filter" "oom" {
  name           = "${var.name_prefix}-oom"
  log_group_name = aws_cloudwatch_log_group.service["system"].name
  pattern        = "?\"Out of memory\" ?oom-kill ?\"Killed process\" ?oom_reaper"

  metric_transformation {
    name          = "OomEvents"
    namespace     = "DroneFeed/${var.name_prefix}"
    value         = "1"
    default_value = "0"
  }
}

# -----------------------------------------------------------------------------
# Host pressure alarms (disk / swap / OOM) → SNS when ops alerts enabled
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  count = local.ops_alerts_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-disk-high"
  alarm_description   = "Root disk used >= ${var.disk_alarm_percent}% on ${var.name_prefix}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = var.disk_alarm_percent
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts[0].arn]
  ok_actions          = [aws_sns_topic.ops_alerts[0].arn]

  metric_query {
    id          = "disk"
    return_data = true
    expression  = "SEARCH('{CWAgent,InstanceId,path,device,fstype} disk_used_percent InstanceId=\"${aws_instance.app.id}\" AND path=\"/\"', 'Average', 300)"
    label       = "RootDiskUsedPercent"
  }

  tags = {
    Name = "${var.name_prefix}-disk-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "swap_high" {
  count = local.ops_alerts_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-swap-high"
  alarm_description   = "Swap used >= ${var.swap_alarm_percent}% (memory pressure / OOM risk) on ${var.name_prefix}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  threshold           = var.swap_alarm_percent
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts[0].arn]
  ok_actions          = [aws_sns_topic.ops_alerts[0].arn]

  metric_query {
    id          = "swap"
    return_data = true
    expression  = "SEARCH('{CWAgent,InstanceId} swap_used_percent InstanceId=\"${aws_instance.app.id}\"', 'Average', 300)"
    label       = "SwapUsedPercent"
  }

  tags = {
    Name = "${var.name_prefix}-swap-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "oom" {
  count = local.ops_alerts_enabled ? 1 : 0

  alarm_name          = "${var.name_prefix}-oom"
  alarm_description   = "Kernel OOM killer activity detected on ${var.name_prefix}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "OomEvents"
  namespace           = "DroneFeed/${var.name_prefix}"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ops_alerts[0].arn]

  tags = {
    Name = "${var.name_prefix}-oom"
  }

  depends_on = [aws_cloudwatch_log_metric_filter.oom]
}

# -----------------------------------------------------------------------------
# CloudWatch dashboard (EC2 + network + agent mem/disk/swap + log widgets)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "${var.name_prefix}-ops"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ${var.name_prefix} ops — EC2 / network / containers"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "EC2 CPU"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id, { stat = "Average" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Status checks"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.app.id, { stat = "Maximum" }],
            [".", "StatusCheckFailed_Instance", ".", ".", { stat = "Maximum" }],
            [".", "StatusCheckFailed_System", ".", ".", { stat = "Maximum" }],
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Network In / Out"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.app.id, { stat = "Sum" }],
            [".", "NetworkOut", ".", ".", { stat = "Sum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "Memory used %"
          region = var.aws_region
          metrics = [
            ["CWAgent", "mem_used_percent", "InstanceId", aws_instance.app.id, { stat = "Average" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "Swap used %"
          region = var.aws_region
          metrics = [
            ["CWAgent", "swap_used_percent", "InstanceId", aws_instance.app.id, { stat = "Average" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "Disk used % (root)"
          region = var.aws_region
          metrics = [
            ["CWAgent", "disk_used_percent", "InstanceId", aws_instance.app.id, "path", "/", "fstype", "xfs", { stat = "Average" }],
            ["CWAgent", "disk_used_percent", "InstanceId", aws_instance.app.id, "path", "/", "fstype", "ext4", { stat = "Average" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "web logs"
          region = var.aws_region
          query  = "SOURCE '/${var.name_prefix}/web' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 13
        width  = 12
        height = 6
        properties = {
          title  = "mediamtx logs"
          region = var.aws_region
          query  = "SOURCE '/${var.name_prefix}/mediamtx' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 19
        width  = 12
        height = 6
        properties = {
          title  = "caddy logs"
          region = var.aws_region
          query  = "SOURCE '/${var.name_prefix}/caddy' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 19
        width  = 12
        height = 6
        properties = {
          title  = "db / bootstrap / system"
          region = var.aws_region
          query  = "SOURCE '/${var.name_prefix}/db' | SOURCE '/${var.name_prefix}/bootstrap' | SOURCE '/${var.name_prefix}/system' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Instance IAM — CloudWatch Agent + awslogs driver
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "cw_agent" {
  statement {
    sid = "CwAgentMetrics"
    actions = [
      "cloudwatch:PutMetricData",
      "ec2:DescribeVolumes",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    sid = "CwAgentLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = flatten([
      for svc in local.log_services : [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name_prefix}/${svc}",
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/${var.name_prefix}/${svc}:*",
      ]
    ])
  }

  statement {
    sid       = "CwAgentLogGroupsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cw_agent" {
  name   = "${var.name_prefix}-cw-agent"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.cw_agent.json
}
