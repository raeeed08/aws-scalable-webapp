# ---------------------------------------------------------------- static assets (served by CloudFront only)
resource "aws_s3_bucket" "static" {
  #checkov:skip=CKV_AWS_18:access is already logged by CloudFront and CloudTrail data events if enabled
  #checkov:skip=CKV_AWS_145:SSE-S3; a KMS key would need a CloudFront key policy, not worth it for public assets
  #checkov:skip=CKV_AWS_144:static assets are rebuilt from Git; no cross-region copy needed
  #checkov:skip=CKV2_AWS_62:no event processing on this bucket
  bucket_prefix = "${local.name}-static-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "static" {
  bucket = aws_s3_bucket.static.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Only this CloudFront distribution may read the bucket (Origin Access Control).
data "aws_iam_policy_document" "static" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.static.arn, "${aws_s3_bucket.static.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "static" {
  bucket     = aws_s3_bucket.static.id
  policy     = data.aws_iam_policy_document.static.json
  depends_on = [aws_s3_bucket_public_access_block.static]
}

locals {
  static_dir   = "${path.module}/../app/static"
  static_types = { css = "text/css", js = "application/javascript", svg = "image/svg+xml", png = "image/png", ico = "image/x-icon" }
}

resource "aws_s3_object" "static" {
  for_each     = fileset(local.static_dir, "**")
  bucket       = aws_s3_bucket.static.id
  key          = "static/${each.value}"
  source       = "${local.static_dir}/${each.value}"
  etag         = filemd5("${local.static_dir}/${each.value}")
  content_type = lookup(local.static_types, reverse(split(".", each.value))[0], "application/octet-stream")
}

# ---------------------------------------------------------------- ALB access logs
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_18:this IS the log bucket
  #checkov:skip=CKV_AWS_145:ALB log delivery only supports SSE-S3
  #checkov:skip=CKV_AWS_144:logs expire after 90 days; no cross-region copy needed
  #checkov:skip=CKV2_AWS_62:no event processing on this bucket
  bucket_prefix = "${local.name}-alb-logs-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB log delivery supports SSE-S3 only
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}
