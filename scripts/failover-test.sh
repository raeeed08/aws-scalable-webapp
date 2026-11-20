#!/usr/bin/env bash
# Forces an RDS Multi-AZ failover and shows the app reconnecting to the standby (new server IP, same endpoint).
set -euo pipefail
cd "$(dirname "$0")/../terraform"
URL=$(terraform output -raw app_url)
REGION=$(terraform console <<< 'var.region' | tr -d '"')
DB=$(terraform console <<< 'aws_db_instance.main.identifier' | tr -d '"')

echo "Before: $(curl -s "$URL/api/db")"
aws rds reboot-db-instance --region "$REGION" --db-instance-identifier "$DB" --force-failover >/dev/null
echo "Failover started at $(date +%T). Polling /api/db every 5 s (Ctrl-C to stop)..."
while true; do
  printf '%s  ' "$(date +%T)"; curl -s -m 5 "$URL/api/db" || echo "(no answer)"; echo
  sleep 5
done
