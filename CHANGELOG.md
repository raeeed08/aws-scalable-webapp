# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-20

### Added
- VPC across two Availability Zones with public, app and database subnets, NAT Gateway per AZ, route tables,
  network ACLs per tier, S3 gateway endpoint, optional Session Manager interface endpoints and VPC Flow Logs.
- EC2 launch template (Amazon Linux 2023, IMDSv2 only, encrypted gp3) and an Auto Scaling group (2 to 6
  instances) with target tracking on CPU, step scaling on requests per instance and rolling instance refresh.
- Application Load Balancer with layer-7 listener rules, health checks and access logs, reachable only from
  CloudFront (prefix list and secret origin header).
- AWS WAF Web ACL on the ALB: AWS Common Rule Set (OWASP Top 10), Known Bad Inputs (Log4Shell), SQL injection
  and a per-client rate limit.
- CloudFront distribution with S3 static assets through Origin Access Control and managed security headers.
- RDS PostgreSQL Multi-AZ, encrypted, TLS only, password managed in Secrets Manager, enhanced monitoring.
- Route 53 alias records and ACM certificates (optional custom domain) and an HTTPS health check.
- CloudWatch dashboard, 10 alarms, SNS email notifications, CloudWatch agent for memory and disk.
- Demo Flask application, smoke, load, failover and Session Manager scripts.
- Architecture diagram (draw.io, SVG, PNG), README and CI (fmt, validate, tflint, Checkov, shellcheck).
