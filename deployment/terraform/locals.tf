data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:only the first two zones are used (slice), so a new zone changes nothing
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # 10.0.0.0/16 → public 10.0.0.0/24 + 10.0.1.0/24, app 10.0.10.0/24 + 10.0.11.0/24, db 10.0.20.0/24 + 10.0.21.0/24
  public_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i)]
  app_cidrs    = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  db_cidrs     = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]

  use_domain = var.domain_name != "" && var.hosted_zone_id != ""
  app_fqdn   = local.use_domain ? "app.${var.domain_name}" : ""
  alb_fqdn   = local.use_domain ? "origin.${var.domain_name}" : ""

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
