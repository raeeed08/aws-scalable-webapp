# WAF on the ALB, as the brief asks: AWS managed rule groups cover the OWASP Top 10 (injection, XSS, bad inputs).
#
# Design note: traffic reaches the ALB through CloudFront, so the request's source IP is a CloudFront address.
# The rate limit therefore counts the client IP that CloudFront writes in X-Forwarded-For, and the AWS IP
# reputation list (which can only check the source IP) is not used here. Moving the Web ACL to CloudFront
# (scope CLOUDFRONT, us-east-1) would fix both; see the README.

resource "aws_wafv2_web_acl" "main" {
  name        = "${local.name}-waf"
  description = "OWASP Top 10 managed rules and per-client rate limit"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-client"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "FORWARDED_IP"
        forwarded_ip_config {
          header_name       = "X-Forwarded-For"
          fallback_behavior = "MATCH"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # OWASP core rule set: XSS, path traversal, bad bots, size limits
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs: Log4Shell (CVE-2021-44228), Java deserialization, host header tricks
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # SQL injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# WAF log group names must start with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_338:retention is a variable: 30 days in the lab, set 365 in production
  #checkov:skip=CKV_AWS_158:encrypted by CloudWatch with AWS-owned keys; a customer KMS key is optional
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  # never write the CloudFront secret header into the logs
  redacted_fields {
    single_header {
      name = "x-origin-verify"
    }
  }
}
