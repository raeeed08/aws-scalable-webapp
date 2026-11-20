resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-pg-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"
  parameter {
    name  = "rds.force_ssl"
    value = "1" # connections must use TLS
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500" # log queries slower than 500 ms
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_353:Performance Insights is not offered on micro classes; enable it on a larger class
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # Multi-AZ: a synchronous standby in the other AZ; RDS fails over automatically (about 1-2 minutes)
  # and the endpoint name stays the same.
  multi_az = true

  db_name  = "appdb"
  username = "appadmin"
  # RDS creates the password and keeps it in Secrets Manager; it never appears in Terraform state or code.
  manage_master_user_password = true

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  port                   = 5432

  backup_retention_period         = 7
  backup_window                   = "02:00-03:00"
  maintenance_window              = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # IAM database authentication available for tools and humans (the app itself uses the managed secret).
  iam_database_authentication_enabled = true

  # OS-level metrics every 60 s (CPU per process, memory, swap), sent to CloudWatch Logs.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-db-final"
  apply_immediately         = var.environment != "prod"
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
