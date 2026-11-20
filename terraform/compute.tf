data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "app" {
  #checkov:skip=CKV_AWS_338:retention is a variable: 30 days in the lab, set 365 in production
  #checkov:skip=CKV_AWS_158:encrypted by CloudWatch with AWS-owned keys; a customer KMS key is optional
  name              = "/app/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_launch_template" "app" {
  name_prefix            = "${local.name}-app-"
  image_id               = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # IMDSv2 only: blocks the SSRF trick that steals instance credentials through the metadata service.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true # 1-minute EC2 metrics, so scaling reacts faster
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region        = var.region
    db_host       = aws_db_instance.main.address
    db_name       = aws_db_instance.main.db_name
    db_secret_arn = aws_db_instance.main.master_user_secret[0].secret_arn
    log_group     = aws_cloudwatch_log_group.app.name
    app_py        = file("${path.module}/../app/app.py")
    environment   = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-app" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  vpc_zone_identifier       = aws_subnet.app[*].id
  min_size                  = var.asg_min
  desired_capacity          = var.asg_desired
  max_size                  = var.asg_max
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB" # replace an instance the ALB sees as unhealthy, not only a stopped one
  health_check_grace_period = 180
  default_instance_warmup   = 120
  metrics_granularity       = "1Minute"
  enabled_metrics           = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupMinSize", "GroupMaxSize", "GroupTotalInstances"]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # A new launch template version (new AMI, new code) is rolled out instance by instance, never all at once.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------- scaling policies
# 1. Target tracking: AWS adds or removes instances to keep the average CPU near the target.
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}

# 2. Step scaling: a sudden traffic burst (requests per instance) adds 1 or 2 instances at once, before the
#    CPU has time to rise.
resource "aws_autoscaling_policy" "requests_step" {
  name                      = "${local.name}-requests-step"
  autoscaling_group_name    = aws_autoscaling_group.app.name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  estimated_instance_warmup = 120

  # Steps are relative to the alarm threshold.
  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = var.requests_per_target_step
    scaling_adjustment          = 1
  }
  step_adjustment {
    metric_interval_lower_bound = var.requests_per_target_step
    scaling_adjustment          = 2
  }
}

resource "aws_cloudwatch_metric_alarm" "requests_high" {
  alarm_name          = "${local.name}-requests-per-target-high"
  alarm_description   = "Burst of requests per instance: step scaling adds capacity."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "RequestCountPerTarget"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.requests_per_target_step
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }
  alarm_actions = [aws_autoscaling_policy.requests_step.arn]
}
