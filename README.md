**[Scalable Web Application with ALB and Auto Scaling](https://github.com/raeeed08/aws-scalable-webapp)** | **[🚧 Feature request](https://github.com/raeeed08/aws-scalable-webapp/issues/new?template=feature_request.md)** | **[🐛 Bug Report](https://github.com/raeeed08/aws-scalable-webapp/issues/new?template=bug_report.md)** | **[❓ General Question](https://github.com/raeeed08/aws-scalable-webapp/issues/new?template=general_question.md)**

**Note**: AWS Solutions Architect – Associate graduation project (Project 1, EC2-based architecture). The whole
solution is deployed from source with Terraform; see [Customizing the Solution](#customizing-the-solution).

## Table of Content

- [Solution Overview](#solution-overview)
- [Architecture Diagram](#architecture-diagram)
- [AWS Services](#aws-services)
- [Customizing the Solution](#customizing-the-solution)
  - [Prerequisites for Customization](#prerequisites-for-customization)
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Test](#2-test)
  - [3. Build and Deploy](#3-build-and-deploy)
  - [4. Verify and demonstrate](#4-verify-and-demonstrate)
- [File Structure](#file-structure)
- [Security](#security)
- [High Availability and Scaling](#high-availability-and-scaling)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Cost](#cost)
- [Design Decisions and Trade-offs](#design-decisions-and-trade-offs)
- [Well-Architected Framework](#well-architected-framework)
- [Clean Up](#clean-up)
- [Collection of operational metrics](#collection-of-operational-metrics)
- [License](#license)

# Solution Overview

A production-grade web application on AWS. EC2 instances run in **private subnets across two Availability
Zones**, behind an **Application Load Balancer** protected by **AWS WAF**. An **Auto Scaling group** keeps
between 2 and 6 instances, scaling with **target tracking** (CPU) and **step scaling** (request bursts).
**CloudFront** is the single public entry point and caches static assets from **S3**. A **Multi-AZ RDS
PostgreSQL** database fails over automatically. **Route 53** provides DNS and health checks, **Systems Manager
Session Manager** replaces SSH and bastion hosts, and **CloudWatch + SNS** watch everything and send alerts.

The demo application ([source/app/app.py](source/app/app.py), Flask) shows on every page **which instance and
which Availability Zone answered**, plus a visit counter stored in RDS. Refreshing the page shows the load
balancer at work. Stopping an instance, failing over the database or loading the CPU shows the architecture
heal and scale itself.

| Path | Purpose |
| --- | --- |
| `/` | HTML page: instance, AZ, visit counter from PostgreSQL |
| `/health` | Load balancer health check (no database call, on purpose) |
| `/api/info` | Instance and AZ as JSON |
| `/api/db` | Database version and server IP (shows the failover) |
| `/api/load` | Burns about 0.5 s of CPU, to trigger Auto Scaling |
| `/static/*` | CSS and images from S3, cached by CloudFront |

# Architecture Diagram

![Architecture diagram](architecture.png)

The diagram is also available as **[architecture.drawio](architecture.drawio)**, which you can open and edit at
[app.diagrams.net](https://app.diagrams.net) (*File → Open from → Device*). It uses the official AWS icons.
An SVG export is in [docs/architecture.svg](docs/architecture.svg).

## Request flow

1. The user opens `https://app.<domain>` (Route 53 alias) or the CloudFront address.
2. **CloudFront** terminates TLS. `/static/*` is served from the edge cache, or from S3 through Origin Access
   Control. Everything else goes to the ALB with a secret `X-Origin-Verify` header.
3. **AWS WAF** inspects the request on the ALB and blocks injection, known exploits and abusive clients.
4. The **ALB listener rules** forward requests that carry the secret header to the target group (`/api/*` and
   pages are separate rules). Requests without it get a 403, so nobody can bypass CloudFront and WAF.
5. An **EC2 instance** in a private subnet answers. It reads the database password from Secrets Manager with its
   instance role and queries **RDS** over TLS.

## Network design

| Tier | AZ A | AZ B | Route to the internet | Who can reach it |
| --- | --- | --- | --- | --- |
| Public | 10.0.0.0/24 | 10.0.1.0/24 | Internet Gateway | CloudFront (ALB security group uses the CloudFront prefix list) |
| App (private) | 10.0.10.0/24 | 10.0.11.0/24 | NAT Gateway of the same AZ | The ALB only, on port 8080 |
| Database (private) | 10.0.20.0/24 | 10.0.21.0/24 | **None** | The app instances only, on port 5432 |

Each private app subnet has its own route table pointing at the NAT Gateway in its own AZ, so losing one AZ
does not cut the other off the internet. A free S3 gateway endpoint keeps S3 traffic off the NAT Gateway.
**Security groups** (stateful) chain the tiers by reference. **Network ACLs** (stateless) add a second wall:
the app subnets accept 8080 from the public subnets only, and the database subnets accept 5432 from the app
subnets only.

# AWS Services

| Service | Configuration | Why |
| --- | --- | --- |
| **VPC** | 10.0.0.0/16, 2 AZs, 3 tiers of subnets, route table per tier, NACLs per tier, VPC Flow Logs | Isolation: only the load balancer and NAT Gateways have public addresses |
| **NAT Gateway** | One per AZ (one shared in the lab profile) | Private instances reach package mirrors and AWS APIs without being reachable from the internet |
| **EC2 + Launch Template** | Amazon Linux 2023, IMDSv2 only, encrypted gp3, instance profile, user data installs the app | Repeatable, hardened instances |
| **Auto Scaling group** | min 2, max 6, both AZs, ELB health checks, rolling instance refresh | Self-healing and elastic capacity |
| **Scaling policies** | Target tracking on CPU (50 %) + step scaling on requests per instance | Smooth scaling for normal load, fast reaction to bursts |
| **Application Load Balancer** | Public subnets, listener rules (`/api/*`, web), health checks on `/health`, access logs to S3 | Layer-7 routing and spreading load across AZs |
| **AWS WAF** | AWS Common Rule Set (OWASP Top 10), Known Bad Inputs (Log4Shell), SQL injection, per-client rate limit | Blocks common web attacks before they reach the app |
| **CloudFront** | TLS, HTTP/2 and HTTP/3, pages not cached, `/static/*` cached from S3, security headers | Lower latency, offloads static files, single entry point |
| **S3** | Private static bucket read only by CloudFront (OAC); ALB log bucket | Durable, cheap storage; no public bucket |
| **RDS Multi-AZ** | PostgreSQL 16, synchronous standby, encrypted, TLS required, 7-day backups, managed password, enhanced monitoring | Automatic failover without changing the endpoint |
| **Route 53** | Alias records (`app.` → CloudFront, `origin.` → ALB) with a domain; HTTPS health check on `/health` always | DNS and an outside-in check of the whole path |
| **Systems Manager** | Session Manager through the instance role | Shell access with no SSH key, no port 22, no bastion |
| **CloudWatch + SNS** | Dashboard, 10 email alarms (+1 that drives step scaling), app/WAF/VPC/RDS logs, memory and disk from the agent | See problems before users report them |
| **Secrets Manager** | Database password created and stored by RDS | No password in code, Terraform state or user data |

# Customizing the Solution

## Prerequisites for Customization

- An AWS account and the [AWS Command Line Interface](https://aws.amazon.com/cli/) v2, configured
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.6 or newer
- Optional: [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
  [Checkov](https://www.checkov.io/), [tflint](https://github.com/terraform-linters/tflint),
  [shellcheck](https://www.shellcheck.net/) and [hey](https://github.com/rakyll/hey) for load tests

### 1. Clone the repository

```bash
git clone https://github.com/raeeed08/aws-scalable-webapp.git
cd aws-scalable-webapp
export MAIN_DIRECTORY=$PWD
```

### 2. Test

The same checks run in [GitHub Actions](.github/workflows/ci.yml) on every push.

```bash
cd $MAIN_DIRECTORY/deployment/terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
tflint --init && tflint
checkov -d . --framework terraform        # 271 passed, 0 failed, 29 skipped with written reasons
shellcheck $MAIN_DIRECTORY/deployment/scripts/*.sh
python3 -m py_compile $MAIN_DIRECTORY/source/app/app.py
```

### 3. Build and Deploy

```bash
cd $MAIN_DIRECTORY/deployment/terraform
cp terraform.tfvars.example terraform.tfvars    # set alarm_email; the lab profile is cheaper and destroyable
terraform init
terraform plan -out tfplan
terraform apply tfplan                          # about 15-20 minutes (RDS Multi-AZ and CloudFront are the slow parts)
terraform output app_url
```

Confirm the SNS subscription email to receive alarms. Instances need 2–3 minutes after launch to install the
app and pass health checks.

**Custom domain (optional):** set `domain_name` and `hosted_zone_id` (a Route 53 public hosted zone you own).
Terraform then issues two ACM certificates and validates them by DNS: one in us-east-1 for CloudFront, one in
the region for the ALB. It creates `app.<domain>` → CloudFront and `origin.<domain>` → ALB, and switches
CloudFront → ALB to HTTPS.

**Main inputs** ([variables.tf](deployment/terraform/variables.tf)):

| Variable | Default | Meaning |
| --- | --- | --- |
| `region` | `eu-west-3` | Deployment region |
| `nat_gateway_per_az` | `true` | `false` = one shared NAT Gateway (cheaper, not highly available) |
| `instance_type` | `t3.micro` | App instance size |
| `asg_min` / `asg_desired` / `asg_max` | 2 / 2 / 6 | Auto Scaling bounds |
| `cpu_target_percent` | 50 | Target tracking value |
| `requests_per_target_step` | 1000 | Requests per instance per minute that trigger step scaling |
| `db_instance_class` | `db.t4g.micro` | RDS size |
| `waf_rate_limit` | 2000 | Requests per client IP per 5 minutes |
| `domain_name`, `hosted_zone_id` | empty | Optional custom domain |
| `alarm_email` | empty | Where alarms are sent |

### 4. Verify and demonstrate

| Script | What it proves |
| --- | --- |
| [deployment/scripts/smoke-test.sh](deployment/scripts/smoke-test.sh) | Requests spread over instances and AZs, direct ALB access returns 403, static files hit the CloudFront cache, WAF blocks an SQL injection, security headers are present |
| [deployment/scripts/load-test.sh](deployment/scripts/load-test.sh) | CPU passes 50 %, the ASG scales out, then back in when the load stops |
| [deployment/scripts/failover-test.sh](deployment/scripts/failover-test.sh) | `--force-failover` on RDS: `/api/db` shows a new server IP behind the same endpoint |
| [deployment/scripts/ssm-shell.sh](deployment/scripts/ssm-shell.sh) | A shell on a private instance with no SSH and no bastion |

**Suggested 5-minute demo video:** open the app and refresh (instance and AZ change); `curl` the ALB directly
(403); run the smoke test; run the load test and show the dashboard going from 2 to 4 instances; terminate an
instance and watch the ASG replace it; run the failover test; open a Session Manager shell.

# File Structure

```
.
├── README.md                     this document
├── architecture.png              architecture diagram (image)
├── architecture.drawio           architecture diagram (editable in draw.io, official AWS icons)
├── docs/architecture.svg         architecture diagram (SVG)
├── CHANGELOG.md, LICENSE, NOTICE
├── CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md
├── .github/
│   ├── workflows/ci.yml          Terraform fmt/validate, tflint, Checkov, shellcheck
│   ├── ISSUE_TEMPLATE/           bug report, feature request, general question
│   └── PULL_REQUEST_TEMPLATE.md
├── deployment/
│   ├── terraform/
│   │   ├── versions.tf           providers (region + us-east-1 for CloudFront certificates and health-check alarm)
│   │   ├── variables.tf, locals.tf, outputs.tf, terraform.tfvars.example
│   │   ├── network.tf            VPC, subnets, IGW, NAT, route tables, NACLs, endpoints, Flow Logs
│   │   ├── security.tf           security groups, origin secret
│   │   ├── iam.tf                instance role (SSM, CloudWatch agent, one secret), Flow Logs role
│   │   ├── storage.tf            S3 static bucket (OAC) and ALB log bucket
│   │   ├── database.tf           RDS PostgreSQL Multi-AZ
│   │   ├── compute.tf            launch template, Auto Scaling group, scaling policies
│   │   ├── user_data.sh.tftpl    instance boot script
│   │   ├── alb.tf, waf.tf, cdn.tf   ALB and listener rules, WAF, CloudFront
│   │   ├── dns.tf                ACM, Route 53 records and health check
│   │   └── monitoring.tf         SNS, alarms, dashboard
│   └── scripts/                  smoke, load, failover and Session Manager scripts
└── source/
    └── app/                      Flask application, static assets, requirements
```

# Security

| Control | Where |
| --- | --- |
| No compute in public subnets; database subnets have no internet route | [network.tf](deployment/terraform/network.tf) |
| Security groups chained by reference; default security group stripped of all rules | [security.tf](deployment/terraform/security.tf) |
| ALB reachable only from CloudFront (prefix list + secret header, 403 otherwise) | [security.tf](deployment/terraform/security.tf), [alb.tf](deployment/terraform/alb.tf) |
| WAF: OWASP Top 10, Log4Shell, SQL injection, rate limit; secret header redacted from WAF logs | [waf.tf](deployment/terraform/waf.tf) |
| No SSH: Session Manager only, every session logged | [iam.tf](deployment/terraform/iam.tf) |
| IMDSv2 required (blocks credential theft through SSRF) | [compute.tf](deployment/terraform/compute.tf) |
| Least-privilege instance role: it can read one secret, nothing else | [iam.tf](deployment/terraform/iam.tf) |
| Encryption at rest (EBS, RDS, S3) and in transit (TLS viewer side, `rds.force_ssl=1`) | several files |
| Database password never in code or state (`manage_master_user_password`) | [database.tf](deployment/terraform/database.tf) |
| S3 buckets private, public access blocked, TLS-only policy | [storage.tf](deployment/terraform/storage.tf) |
| Security headers (HSTS, X-Frame-Options, nosniff) added by CloudFront | [cdn.tf](deployment/terraform/cdn.tf) |
| VPC Flow Logs, ALB access logs, WAF logs, RDS logs | several files |

**Static analysis:** Checkov runs in CI: 271 checks passed, 0 failed. 29 checks are skipped, each with its
reason written next to the resource (`#checkov:skip=...:reason`), for example "ALB log delivery only supports
SSE-S3". See also [SECURITY.md](SECURITY.md).

# High Availability and Scaling

| Failure or event | What happens |
| --- | --- |
| An instance crashes or fails `/health` | The ALB stops sending it traffic within about 45 s; the ASG (ELB health checks) replaces it |
| A whole AZ fails | The ALB, the ASG and RDS keep running in the other AZ; the ASG launches replacements there; each AZ has its own NAT Gateway |
| The primary database fails | RDS promotes the synchronous standby, usually in 1–2 minutes; the endpoint name stays the same |
| CPU rises (normal growth) | **Target tracking** keeps the average CPU near 50 % |
| Sudden burst of requests | **Step scaling**: over 1,000 requests per instance per minute adds 1 instance, over 2,000 adds 2 |
| New code or AMI | A new launch template version triggers a **rolling instance refresh** (at least 50 % stays healthy) |

# Monitoring and Alerting

- **Dashboard** (`dashboard_url` output): requests and 5xx, p50/p95 latency, healthy instances vs desired
  capacity, CPU of instances and database, WAF allowed vs blocked, database connections and free storage,
  instance memory and disk.
- **Alarms → SNS → email:** ALB 5xx, app 5xx, unhealthy hosts, no healthy host, p95 latency over 1 s,
  database CPU, free storage and connections, WAF blocks, and a Route 53 health check of the whole path.
- **Logs:** app (CloudWatch agent), WAF, VPC Flow Logs, RDS PostgreSQL and enhanced monitoring, ALB access logs.

# Cost

Approximate on-demand prices in eu-west-3, in USD per month (730 hours), before free tier. Check them with the
[AWS Pricing Calculator](https://calculator.aws/) before deploying.

| Item | Default (HA) profile | Lab profile |
| --- | --- | --- |
| NAT Gateway (hourly part) | 2 × ~35 | 1 × ~35 |
| Application Load Balancer | ~20 | ~20 |
| EC2 2 × t3.micro | ~17 | ~17 |
| RDS db.t4g.micro Multi-AZ + 20 GB gp3 | ~30 | ~30 |
| AWS WAF (Web ACL + 4 rules) | ~9 + requests | ~9 + requests |
| Public IPv4 addresses (NAT, ALB) | ~15 | ~11 |
| CloudWatch, Route 53 health check, Secrets Manager | ~6 | ~6 |
| CloudFront | free tier for low traffic | free tier |
| **Total** | **~165** | **~130** |

That is about 0.20 USD per hour. **Deploy, record the demo, and destroy the same day: a few dollars.**

# Design Decisions and Trade-offs

- **The WAF is on the ALB, as the brief asks.** Traffic comes through CloudFront, so WAF sees CloudFront's IP
  addresses as the source. The rate limit therefore counts the client IP that CloudFront writes in
  `X-Forwarded-For`, and the AWS IP reputation list (which only checks the source IP) is not used. In
  production I would move the Web ACL to CloudFront (scope `CLOUDFRONT`, us-east-1): it then sees real client
  IPs and blocks attacks at the edge.
- **Route 53 points users at CloudFront, not at the ALB.** CloudFront is the right entry point. The ALB alias the
  brief asks for exists as `origin.<domain>`, which CloudFront uses as its HTTPS origin.
- **The ALB only answers CloudFront.** The CloudFront prefix list alone is not enough, because every CloudFront
  distribution shares those IPs, so a secret header is checked in the listener rules.
- **`/health` does not touch the database.** Otherwise a slow database would make every instance look unhealthy
  and the ASG would replace healthy instances in a loop.
- **One NAT Gateway per AZ by default.** About 35 USD per month more, but a single NAT Gateway is a single point
  of failure for outbound traffic. The lab profile accepts that risk to save money.
- **No bastion host.** Session Manager gives an audited shell without opening any inbound port.
- **No ACM certificate without a domain.** CloudFront's default certificate covers `*.cloudfront.net`, and
  CloudFront → ALB uses HTTP inside AWS in that mode. With a domain, both legs are HTTPS (TLS 1.2+).

# Well-Architected Framework

| Pillar | How this design applies it |
| --- | --- |
| Operational excellence | Everything in Terraform; CI with fmt, validate, tflint and Checkov; rolling instance refresh; dashboard and runbook scripts |
| Security | Private compute, chained security groups, NACLs, WAF, no SSH, IMDSv2, least-privilege role, encryption, managed secrets, logs |
| Reliability | 2 AZs for every tier, ELB health checks, self-healing ASG, RDS Multi-AZ, NAT Gateway per AZ, Route 53 health check |
| Performance efficiency | CloudFront edge caching and HTTP/3, static files offloaded to S3, target tracking + step scaling, gp3 storage |
| Cost optimization | Right-sized defaults, scale-in to 2, free S3 gateway endpoint, lab profile, log expiry |
| Sustainability | Scale to demand instead of over-provisioning; Graviton (t4g) for the database |

# Clean Up

```bash
cd $MAIN_DIRECTORY/deployment/terraform
terraform destroy
```

With the lab profile, deletion protection is off and no final snapshot is taken, so this removes everything.
With the default profile, first set `db_deletion_protection = false` and `alb_deletion_protection = false`, then
apply and destroy.

# Collection of operational metrics

This solution sends no usage data anywhere. All metrics and logs stay in your own AWS account (CloudWatch,
S3).

# License

Copyright 2026 Raed Aroua.

Licensed under the Apache License, Version 2.0 (the "License"). You may not use this project except in
compliance with the License. A copy of the License is in [LICENSE](LICENSE) and at
http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing permissions and limitations
under the License.
