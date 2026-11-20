# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository, or contact the maintainer
through the [GitHub profile of @raeeed08](https://github.com/raeeed08).

Include the affected file or resource, how to reproduce the problem, and its impact. You will get an answer
within 7 days.

## Scope

This is a reference architecture for learning. Before running it in production, review in particular:

- the design trade-offs listed in the README (WAF on the ALB rather than CloudFront, HTTP between CloudFront
  and the ALB when no domain is configured);
- the Checkov checks skipped with a written reason (`#checkov:skip` comments in `deployment/terraform`).

## Never commit

`terraform.tfvars`, `*.tfstate`, AWS credentials or any secret. They are listed in `.gitignore`.
