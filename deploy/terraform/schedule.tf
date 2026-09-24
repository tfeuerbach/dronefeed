# Weekday start/stop via EventBridge Scheduler (timezone-aware cron).
# Default off — enable with enable_business_hours_schedule = true (e.g. 8→18 local).

data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_business_hours_schedule ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.enable_business_hours_schedule ? 1 : 0

  name               = "${var.name_prefix}-ec2-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
}

data "aws_iam_policy_document" "scheduler_ec2" {
  count = var.enable_business_hours_schedule ? 1 : 0

  statement {
    sid = "StartStopOneInstance"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = [aws_instance.app.arn]
  }

  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  count = var.enable_business_hours_schedule ? 1 : 0

  name   = "${var.name_prefix}-ec2-scheduler"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_ec2[0].json
}

resource "aws_scheduler_schedule" "ec2_start" {
  count = var.enable_business_hours_schedule ? 1 : 0

  name       = "${var.name_prefix}-ec2-start"
  group_name = "default"
  state      = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  # Minute Hour Day-of-month Month Day-of-week Year
  schedule_expression          = "cron(0 ${var.schedule_start_hour} ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  description                  = "Start DroneFeed EC2 at ${var.schedule_start_hour}:00 ${var.schedule_timezone} Mon–Fri"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input = jsonencode({
      InstanceIds = [aws_instance.app.id]
    })
  }
}

resource "aws_scheduler_schedule" "ec2_stop" {
  count = var.enable_business_hours_schedule ? 1 : 0

  name       = "${var.name_prefix}-ec2-stop"
  group_name = "default"
  state      = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "cron(0 ${var.schedule_stop_hour} ? * MON-FRI *)"
  schedule_expression_timezone = var.schedule_timezone
  description                  = "Stop DroneFeed EC2 at ${var.schedule_stop_hour}:00 ${var.schedule_timezone} Mon–Fri"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input = jsonencode({
      InstanceIds = [aws_instance.app.id]
    })
  }
}
