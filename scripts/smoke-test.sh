#!/usr/bin/env bash
# After `terraform apply`: proves load balancing, the CloudFront-only rule, caching and the WAF.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
URL=$(terraform output -raw app_url)
ALB=$(terraform output -raw alb_dns_name)

echo "== 1. Load balancing across instances and AZs (10 requests)"
for i in $(seq 10); do curl -s "$URL/api/info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["instance"], d["az"])'; done | sort | uniq -c

echo "== 2. Database through the app"
curl -s "$URL/api/db"; echo

echo "== 3. Direct access to the ALB is refused (must go through CloudFront): expect 403"
curl -s -o /dev/null -w "%{http_code}\n" "http://$ALB/"

echo "== 4. Static files are cached at the edge: second request should be 'Hit from cloudfront'"
curl -s -o /dev/null "$URL/static/style.css"
curl -sI "$URL/static/style.css" | grep -i '^x-cache'

echo "== 5. WAF blocks an SQL injection attempt: expect 403"
curl -s -o /dev/null -w "%{http_code}\n" "$URL/api/info?id=1%27%20OR%20%271%27=%271"

echo "== 6. Security headers added by CloudFront"
curl -sI "$URL/" | grep -iE '^(strict-transport-security|x-content-type-options|x-frame-options):'
