data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_origin_access_control" "static" {
  name                              = "${local.name}-static-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  #checkov:skip=CKV_AWS_68:the brief puts WAF on the ALB; moving it to CloudFront is described in the README
  #checkov:skip=CKV2_AWS_47:same: the Web ACL is on the ALB
  #checkov:skip=CKV_AWS_86:standard logging needs an ACL-enabled bucket; ALB access logs cover requests
  #checkov:skip=CKV_AWS_374:the site is public worldwide
  #checkov:skip=CKV_AWS_310:single origin region by design (Multi-AZ, not multi-region)
  #checkov:skip=CKV_AWS_305:dynamic app: / is served by the application
  #checkov:skip=CKV_AWS_174:without a custom domain CloudFront's default certificate is used; with a domain the minimum is TLSv1.2_2021
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name}: dynamic pages from the ALB, /static/* from S3"
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  aliases         = local.use_domain ? [local.app_fqdn] : []

  origin {
    origin_id   = "alb"
    domain_name = local.use_domain ? local.alb_fqdn : aws_lb.main.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.use_domain ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  origin {
    origin_id                = "static"
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.static.id
  }

  # Pages and API: not cached, every request reaches the app.
  default_cache_behavior {
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  # Static assets: cached at the edge, served from S3, never touch the instances.
  ordered_cache_behavior {
    path_pattern               = "/static/*"
    target_origin_id           = "static"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.use_domain
    acm_certificate_arn            = local.use_domain ? aws_acm_certificate_validation.cloudfront[0].certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }
}
