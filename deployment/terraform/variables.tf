variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "scalable-webapp"
}

variable "environment" {
  description = "Environment name (lab, prod...)."
  type        = string
  default     = "lab"
}

variable "region" {
  description = "AWS region. eu-west-3 (Paris) is the closest to Tunisia."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "nat_gateway_per_az" {
  description = "true: one NAT Gateway per AZ (highly available). false: one shared NAT Gateway (cheaper, for a lab)."
  type        = bool
  default     = true
}

variable "enable_ssm_vpc_endpoints" {
  description = "Interface endpoints for Session Manager, so instances reach SSM without the NAT Gateway."
  type        = bool
  default     = false
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min" {
  type    = number
  default = 2
}

variable "asg_desired" {
  type    = number
  default = 2
}

variable "asg_max" {
  type    = number
  default = 6
}

variable "cpu_target_percent" {
  description = "Target tracking: keep the average CPU of the group around this value."
  type        = number
  default     = 50
}

variable "requests_per_target_step" {
  description = "Step scaling: add instances when one instance receives more than this many requests per minute."
  type        = number
  default     = 1000
}

variable "db_engine_version" {
  type    = string
  default = "16"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_deletion_protection" {
  description = "Keep true in production. Set false in a lab so `terraform destroy` works."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = false
}

variable "alb_deletion_protection" {
  type    = bool
  default = true
}

variable "waf_rate_limit" {
  description = "Requests allowed per client IP in any 5-minute window before WAF blocks it."
  type        = number
  default     = 2000
}

variable "domain_name" {
  description = "Optional. e.g. example.com. When set (with hosted_zone_id), the app is served on app.<domain> with ACM certificates."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route 53 public hosted zone id for domain_name."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email that receives CloudWatch alarms through SNS (confirm the subscription email)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}
