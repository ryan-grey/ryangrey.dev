#!/usr/bin/env bash
#
# Monthly automated test of the alert pipeline.
#
# Once a month, forces the CloudFront 5xx alarm into ALARM state. That
# exercises the whole delivery chain end to end:
#
#   alarm -> SNS -> Lambda -> SES (alerts@ryangrey.dev) -> inbox
#
# The alarm self-recovers to OK on its next evaluation (~5 min) on real
# datapoints, so this leaves no lasting state.
#
# Why it exists: the only delivery path runs through a Lambda. If that
# function breaks -- a bad IAM scope, an SES change, a code error -- alarms
# still fire and SNS still publishes while nothing reaches the inbox. Every
# console screen looks healthy. This is the heartbeat that catches it.
#
# Uses EventBridge Scheduler's universal target to call cloudwatch:SetAlarmState
# directly. No Lambda, no GitHub Actions cron (GitHub disables scheduled
# workflows after 60 days of repo inactivity, which would stop the test
# silently -- precisely the failure this guards against).
#
# Requires IAM + Scheduler admin. Run in CloudShell. Idempotent.
#
# Usage:
#   curl -fsSL -o setup-alert-pipeline-test.sh https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra/setup-alert-pipeline-test.sh
#   bash setup-alert-pipeline-test.sh

set -euo pipefail

REGION="us-east-1"
ALARM="cloudfront-5xx-error-rate"
SCHEDULE="ryangrey-alert-pipeline-test"
ROLE_NAME="ryangrey-scheduler-alarm-test-role"
# 14:00 UTC on the 1st of each month
CRON="cron(0 14 1 * ? *)"

ACCT="$(aws sts get-caller-identity --query Account --output text)"
ALARM_ARN="arn:aws:cloudwatch:${REGION}:${ACCT}:alarm:${ALARM}"

echo "Account:  ${ACCT}"
echo "Alarm:    ${ALARM}"
echo "Schedule: ${CRON}"
echo

# ---------------------------------------------------------------------------
# 1. Role that EventBridge Scheduler assumes
# ---------------------------------------------------------------------------
TRUST="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"scheduler.amazonaws.com\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCT}\"}}}]}"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[=] Role ${ROLE_NAME} exists"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
else
  echo "[+] Creating role ${ROLE_NAME}"
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "Lets EventBridge Scheduler run the monthly alert-pipeline test" \
    --assume-role-policy-document "$TRUST" >/dev/null
  echo "[*] Waiting for role propagation"
  sleep 15
fi

# Least privilege: SetAlarmState on exactly this one alarm.
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name set-alarm-state \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"cloudwatch:SetAlarmState\",\"Resource\":\"${ALARM_ARN}\"}]}"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# ---------------------------------------------------------------------------
# 2. The schedule itself
# ---------------------------------------------------------------------------
INPUT="{\"AlarmName\":\"${ALARM}\",\"StateValue\":\"ALARM\",\"StateReason\":\"Monthly automated test of the alert delivery pipeline. If you are reading this email, alarm -> SNS -> Lambda -> SES -> inbox is working. The alarm returns to OK within about 5 minutes.\"}"
TARGET="{\"Arn\":\"arn:aws:scheduler:::aws-sdk:cloudwatch:setAlarmState\",\"RoleArn\":\"${ROLE_ARN}\",\"Input\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$INPUT")}"

if aws scheduler get-schedule --name "$SCHEDULE" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Updating schedule ${SCHEDULE}"
  aws scheduler update-schedule --name "$SCHEDULE" --region "$REGION" \
    --schedule-expression "$CRON" --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' --target "$TARGET" >/dev/null
else
  echo "[+] Creating schedule ${SCHEDULE}"
  aws scheduler create-schedule --name "$SCHEDULE" --region "$REGION" \
    --description "Monthly end-to-end test of the ryangrey.dev alert pipeline" \
    --schedule-expression "$CRON" --schedule-expression-timezone "UTC" \
    --flexible-time-window '{"Mode":"OFF"}' --target "$TARGET" >/dev/null
fi

echo
echo "Done."
aws scheduler get-schedule --name "$SCHEDULE" --region "$REGION" \
  --query '{Name:Name,State:State,Cron:ScheduleExpression,Target:Target.Arn}' --output table
echo "Next run: 14:00 UTC on the 1st of the month."
echo
echo "Test it now without waiting:"
echo "  aws cloudwatch set-alarm-state --region ${REGION} --alarm-name ${ALARM} --state-value ALARM --state-reason 'Manual pipeline test'"
