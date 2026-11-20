# ---------------------------------------------------------------- certificates (only with a domain)
resource "aws_acm_certificate" "cloudfront" {
  count             = local.use_domain ? 1 : 0
  provider          = aws.us_east_1 # CloudFront only uses certificates from us-east-1
  domain_name       = local.app_fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "alb" {
  count             = local.use_domain ? 1 : 0
  domain_name       = local.alb_fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

locals {
  cert_validation = local.use_domain ? {
    for dvo in concat(tolist(aws_acm_certificate.cloudfront[0].domain_validation_options), tolist(aws_acm_certificate.alb[0].domain_validation_options)) :
    dvo.domain_name => { name = dvo.resource_record_name, type = dvo.resource_record_type, value = dvo.resource_record_value }
  } : {}
}

resource "aws_route53_record" "cert_validation" {
  for_each        = local.cert_validation
  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  count                   = local.use_domain ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[local.app_fqdn].fqdn]
}

resource "aws_acm_certificate_validation" "alb" {
  count                   = local.use_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[local.alb_fqdn].fqdn]
}

# ---------------------------------------------------------------- records
# app.<domain> → CloudFront (what users open)
resource "aws_route53_record" "app" {
  for_each = local.use_domain ? toset(["A", "AAAA"]) : toset([])
  zone_id  = var.hosted_zone_id
  name     = local.app_fqdn
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# origin.<domain> → ALB (the alias record the brief asks for; CloudFront connects to it over HTTPS)
resource "aws_route53_record" "alb" {
  count   = local.use_domain ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = local.alb_fqdn
  type    = "A"
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------- health check (always on)
# Checks the whole path a user takes (CloudFront → WAF → ALB → instance) from AWS locations around the world.
resource "aws_route53_health_check" "app" {
  fqdn              = local.use_domain ? local.app_fqdn : aws_cloudfront_distribution.main.domain_name
  type              = "HTTPS"
  port              = 443
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = true
  tags              = { Name = "${local.name}-health" }
}
