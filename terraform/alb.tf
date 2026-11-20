resource "aws_lb" "main" {
  #checkov:skip=CKV2_AWS_76:AWSManagedRulesKnownBadInputsRuleSet (Log4JRCE) is attached through aws_wafv2_web_acl_association; the graph check does not follow it
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  idle_timeout               = 60
  enable_deletion_protection = var.alb_deletion_protection

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:HTTP only on the hop from the ALB to instances in private subnets
  name                 = "${local.name}-app"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  # /health does not touch the database: a slow database must not make every instance look dead.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }
}

# With a domain: HTTPS between CloudFront and the ALB, certificate for origin.<domain>.
# Without a domain (lab): HTTP between CloudFront and the ALB; viewers still use HTTPS on CloudFront.
resource "aws_lb_listener" "main" {
  #checkov:skip=CKV_AWS_378:HTTP only between CloudFront and the ALB in lab mode without a domain; HTTPS when domain_name is set
  load_balancer_arn = aws_lb.main.arn
  port              = local.alb_port
  protocol          = local.use_domain ? "HTTPS" : "HTTP"
  ssl_policy        = local.use_domain ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn   = local.use_domain ? aws_acm_certificate_validation.alb[0].certificate_arn : null

  # Anything that did not come through CloudFront (no secret header) is refused.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden: use the CloudFront address."
      status_code  = "403"
    }
  }
}

# Layer-7 routing: API calls and pages are matched separately (both on the app target group here, ready to
# be split into separate services later), and both require the CloudFront secret header.
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 10
  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener_rule" "web" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 20
  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
