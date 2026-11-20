# ---------------------------------------------------------------- VPC, subnets, gateways
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
  # The ALB and NAT Gateways live here; nothing gets a public IP automatically.
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "db" }
}

resource "aws_eip" "nat" {
  count  = var.nat_gateway_per_az ? 2 : 1
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count         = var.nat_gateway_per_az ? 2 : 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${local.azs[count.index]}" }
  depends_on    = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------- route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ: each AZ leaves through its own NAT Gateway, so losing an AZ
# does not cut the other AZ off the internet.
resource "aws_route_table" "app" {
  count  = 2
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.nat_gateway_per_az ? count.index : 0].id
  }
  tags = { Name = "${local.name}-rt-app-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# The database tier has no route to the internet at all.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-db" }
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# Free gateway endpoint: S3 traffic (packages, logs) stays on the AWS network.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${local.name}-s3-endpoint" }
}

# Optional interface endpoints for Session Manager (about 7 USD per endpoint per AZ per month).
resource "aws_vpc_endpoint" "ssm" {
  for_each            = var.enable_ssm_vpc_endpoints ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.key}-endpoint" }
}

# ---------------------------------------------------------------- network ACLs (stateless, subnet level)
resource "aws_network_acl" "public" {
  #checkov:skip=CKV_AWS_231:1024-65535 is the return range the NAT Gateway needs; security groups still block 3389
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id
  tags       = { Name = "${local.name}-nacl-public" }

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  # return traffic for connections opened from inside (NAT Gateway, ALB to targets)
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }
  ingress {
    rule_no    = 130
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

resource "aws_network_acl" "app" {
  #checkov:skip=CKV_AWS_231:1024-65535 is the return range for outbound connections; security groups still block 3389
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.app[*].id
  tags       = { Name = "${local.name}-nacl-app" }

  # app port from the ALB subnets only
  dynamic "ingress" {
    for_each = local.public_cidrs
    content {
      rule_no    = 100 + ingress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 8080
      to_port    = 8080
    }
  }
  # return traffic (internet through NAT, database, AWS APIs)
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }
  ingress {
    rule_no    = 210
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 443
    to_port    = 443
  }
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

resource "aws_network_acl" "db" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${local.name}-nacl-db" }

  dynamic "ingress" {
    for_each = local.app_cidrs
    content {
      rule_no    = 100 + ingress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 5432
      to_port    = 5432
    }
  }
  # traffic between the primary and the standby, managed by RDS
  dynamic "ingress" {
    for_each = local.db_cidrs
    content {
      rule_no    = 200 + ingress.key
      protocol   = "-1"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 0
      to_port    = 0
    }
  }
  dynamic "egress" {
    for_each = local.app_cidrs
    content {
      rule_no    = 100 + egress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = egress.value
      from_port  = 1024
      to_port    = 65535
    }
  }
  dynamic "egress" {
    for_each = local.db_cidrs
    content {
      rule_no    = 200 + egress.key
      protocol   = "-1"
      action     = "allow"
      cidr_block = egress.value
      from_port  = 0
      to_port    = 0
    }
  }
}

# ---------------------------------------------------------------- VPC Flow Logs (who talks to whom)
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:retention is a variable: 30 days in the lab, set 365 in production
  #checkov:skip=CKV_AWS_158:encrypted by CloudWatch with AWS-owned keys; a customer KMS key is optional
  name              = "/vpc/${local.name}/flow-logs"
  retention_in_days = var.log_retention_days
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}
