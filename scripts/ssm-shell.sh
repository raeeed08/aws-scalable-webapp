#!/usr/bin/env bash
# Shell on one app instance through Session Manager: no SSH key, no port 22, no bastion.
# Needs the Session Manager plugin for the AWS CLI.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
REGION=$(terraform console <<< 'var.region' | tr -d '"')
ASG=$(terraform output -raw asg_name)
ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
exec aws ssm start-session --region "$REGION" --target "$ID"
