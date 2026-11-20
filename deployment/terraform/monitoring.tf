# ---------------------------------------------------------------- notifications
# Left without a KMS key on purpose: CloudWatch alarms cannot publish to a topic encrypted with the AWS managed
# key. Alarm messages carry no secrets. Use a customer managed key with a CloudWatch grant if your policy demands.
resource "aws_sns_topic" "alarms" {
  #checkov:skip=CKV_AWS_26:alarm messages hold no secrets; CloudWatch cannot publish to a topic using the AWS managed key
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# Route 53 health-check metrics only exist in us-east-1, and an alarm can only notify a topic in its own region.
resource "aws_sns_topic" "alarms_us_east_1" {
  #checkov:skip=CKV_AWS_26:alarm messages hold no secrets; CloudWatch cannot publish to a topic using the AWS managed key
  provider = aws.us_east_1
  name     = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "email_us_east_1" {
  count     = var.alarm_email != "" ? 1 : 0
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alarms_us_east_1.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------- alarms
locals {
  alb_dims = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dims  = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
  db_dims  = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  alarms = {
    alb-5xx = {
      description = "The load balancer itself returns 5xx errors (no healthy target, misconfiguration)."
      namespace   = "AWS/ApplicationELB", metric = "HTTPCode_ELB_5XX_Count", stat = "Sum", period = 300
      threshold   = 10, op = "GreaterThanThreshold", dims = local.alb_dims
    }
    target-5xx = {
      description = "The application returns 5xx errors."
      namespace   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", stat = "Sum", period = 300
      threshold   = 10, op = "GreaterThanThreshold", dims = local.tg_dims
    }
    unhealthy-hosts = {
      description = "At least one instance fails its health check."
      namespace   = "AWS/ApplicationELB", metric = "UnHealthyHostCount", stat = "Maximum", period = 60
      threshold   = 0, op = "GreaterThanThreshold", dims = local.tg_dims
    }
    no-healthy-host = {
      description = "No healthy instance at all: the site is down."
      namespace   = "AWS/ApplicationELB", metric = "HealthyHostCount", stat = "Minimum", period = 60
      threshold   = 1, op = "LessThanThreshold", dims = local.tg_dims
    }
    rds-cpu = {
      description = "Database CPU above 80 % for 10 minutes."
      namespace   = "AWS/RDS", metric = "CPUUtilization", stat = "Average", period = 300
      threshold   = 80, op = "GreaterThanThreshold", dims = local.db_dims
    }
    rds-storage = {
      description = "Less than 2 GB of free database storage."
      namespace   = "AWS/RDS", metric = "FreeStorageSpace", stat = "Minimum", period = 300
      threshold   = 2147483648, op = "LessThanThreshold", dims = local.db_dims
    }
    rds-connections = {
      description = "Unusually many database connections."
      namespace   = "AWS/RDS", metric = "DatabaseConnections", stat = "Maximum", period = 300
      threshold   = 60, op = "GreaterThanThreshold", dims = local.db_dims
    }
    waf-blocked = {
      description = "WAF blocks many requests: an attack or a false positive to review."
      namespace   = "AWS/WAFV2", metric = "BlockedRequests", stat = "Sum", period = 300
      threshold   = 100, op = "GreaterThanThreshold"
      dims        = { WebACL = aws_wafv2_web_acl.main.name, Region = var.region, Rule = "ALL" }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "main" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.stat
  period              = each.value.period
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  dimensions          = each.value.dims
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# p95 latency needs an extended statistic, so it is its own resource.
resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name}-latency-p95"
  alarm_description   = "95 % of requests should be answered in under 1 second."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  dimensions          = local.tg_dims
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "health_check" {
  provider            = aws.us_east_1
  alarm_name          = "${local.name}-site-down"
  alarm_description   = "Route 53 health checkers cannot load /health through CloudFront."
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  dimensions          = { HealthCheckId = aws_route53_health_check.app.id }
  alarm_actions       = [aws_sns_topic.alarms_us_east_1.arn]
  ok_actions          = [aws_sns_topic.alarms_us_east_1.arn]
}

# ---------------------------------------------------------------- dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Requests and errors", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Response time (p50, p95)", region = var.region, period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title = "Instances (Auto Scaling)", region = var.region, stat = "Average", period = 60
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            [".", "GroupDesiredCapacity", ".", "."],
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title = "CPU: instances and database", region = var.region, stat = "Average", period = 60
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier],
          ]
          annotations = { horizontal = [{ value = var.cpu_target_percent, label = "scaling target" }] }
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title = "WAF: allowed vs blocked", region = var.region, stat = "Sum", period = 300
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", aws_wafv2_web_acl.main.name, "Region", var.region, "Rule", "ALL"],
            [".", "BlockedRequests", ".", ".", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title = "Database: connections and free storage (GB)", region = var.region, period = 300
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Maximum" }],
            [".", "FreeStorageSpace", ".", ".", { stat = "Minimum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "Instance memory and disk (CloudWatch agent)", region = var.region, stat = "Average", period = 60
          metrics = [
            ["WebApp", "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            [".", "disk_used_percent", ".", "."],
          ]
        }
      },
    ]
  })
}
