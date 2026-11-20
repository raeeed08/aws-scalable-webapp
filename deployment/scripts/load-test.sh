#!/usr/bin/env bash
# Pushes CPU over the 50 % target so Auto Scaling adds instances. Watch the dashboard or run:
#   watch -n 15 aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <asg> \
#     --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances)]'
# Uses `hey` (https://github.com/rakyll/hey) when installed, else parallel curl.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
URL=$(terraform output -raw app_url)
DURATION=${DURATION:-600}   # seconds
CONCURRENCY=${CONCURRENCY:-40}
echo "Load on $URL/api/load for ${DURATION}s with $CONCURRENCY parallel clients"
if command -v hey >/dev/null; then
  hey -z "${DURATION}s" -c "$CONCURRENCY" "$URL/api/load"
else
  end=$((SECONDS + DURATION))
  while [ $SECONDS -lt $end ]; do
    seq "$CONCURRENCY" | xargs -P "$CONCURRENCY" -I{} curl -s -o /dev/null "$URL/api/load"
  done
fi
echo "Stop here; after a few minutes of low CPU, target tracking scales back in to the minimum."
