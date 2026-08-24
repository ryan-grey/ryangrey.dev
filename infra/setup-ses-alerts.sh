#!/usr/bin/env bash
#
# Builds the SNS -> Lambda -> SES alert pipeline for ryangrey.dev.
#
#   SNS topic (ryangrey-dev-alerts)
#     -> Lambda (formats CloudWatch alarm payloads)
#       -> SES, sending from alerts@ryangrey.dev (DKIM-signed)
#         -> your inbox
#
# Why: SNS's built-in email uses shared sending infrastructure that never
# delivered to the target Gmail address. Sending from a domain identity we
# own and DKIM-sign lands reliably.
#
# Requires IAM/SES/Lambda admin -- run in CloudShell as root or an admin user.
# Idempotent: safe to re-run.
#
# Usage (from CloudShell):
#   curl -fsSL -o setup-ses-alerts.sh https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra/setup-ses-alerts.sh
#   bash setup-ses-alerts.sh

set -euo pipefail

REGION="us-east-1"
DOMAIN="ryangrey.dev"
ZONE_ID="Z07179132S16E6LFL8S10"
SENDER="alerts@${DOMAIN}"
RECIPIENT="${RECIPIENT:-rgrey.web@gmail.com}"
TOPIC_ARN="arn:aws:sns:us-east-1:<AWS_ACCOUNT_ID>:ryangrey-dev-alerts"
FN_NAME="ryangrey-alert-forwarder"
ROLE_NAME="ryangrey-alert-forwarder-role"
SRC="ses_alert_lambda.py"
RAW="https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra/${SRC}"

ACCT="$(aws sts get-caller-identity --query Account --output text)"
echo "Account:   ${ACCT}"
echo "Sender:    ${SENDER}"
echo "Recipient: ${RECIPIENT}"
echo

# ---------------------------------------------------------------------------
# 1. SES domain identity + Easy DKIM
# ---------------------------------------------------------------------------
if aws sesv2 get-email-identity --email-identity "$DOMAIN" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] SES identity ${DOMAIN} exists"
else
  echo "[+] Creating SES identity ${DOMAIN}"
  aws sesv2 create-email-identity --email-identity "$DOMAIN" --region "$REGION" >/dev/null
fi

TOKENS="$(aws sesv2 get-email-identity --email-identity "$DOMAIN" --region "$REGION" \
  --query 'DkimAttributes.Tokens' --output text)"
echo "[*] DKIM tokens: ${TOKENS}"

# ---------------------------------------------------------------------------
# 2. Route 53: DKIM CNAMEs + SPF + DMARC
# ---------------------------------------------------------------------------
CHANGES=""
for T in $TOKENS; do
  CHANGES="${CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${T}._domainkey.${DOMAIN}\",\"Type\":\"CNAME\",\"TTL\":1800,\"ResourceRecords\":[{\"Value\":\"${T}.dkim.amazonses.com\"}]}},"
done
CHANGES="${CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${DOMAIN}\",\"Type\":\"TXT\",\"TTL\":1800,\"ResourceRecords\":[{\"Value\":\"\\\"v=spf1 include:amazonses.com ~all\\\"\"}]}},"
CHANGES="${CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"_dmarc.${DOMAIN}\",\"Type\":\"TXT\",\"TTL\":1800,\"ResourceRecords\":[{\"Value\":\"\\\"v=DMARC1; p=none;\\\"\"}]}}"

echo "[+] Upserting DKIM/SPF/DMARC records into ${ZONE_ID}"
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Comment\":\"SES domain identity for ${DOMAIN}\",\"Changes\":[${CHANGES}]}" \
  --query 'ChangeInfo.Id' --output text)"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
echo "[+] DNS records live"

# ---------------------------------------------------------------------------
# 3. Wait for SES to verify DKIM (usually 1-5 min, can be longer)
# ---------------------------------------------------------------------------
echo "[*] Waiting for DKIM verification"
for i in $(seq 1 40); do
  ST="$(aws sesv2 get-email-identity --email-identity "$DOMAIN" --region "$REGION" \
        --query 'DkimAttributes.Status' --output text)"
  [ "$ST" = "SUCCESS" ] && { echo "[+] DKIM verified"; break; }
  echo "    status=${ST} (${i}/40)"
  sleep 15
done

# ---------------------------------------------------------------------------
# 4. SES sandbox: the RECIPIENT must be a verified identity too
# ---------------------------------------------------------------------------
if aws sesv2 get-email-identity --email-identity "$RECIPIENT" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Recipient identity already exists"
else
  echo "[+] Creating recipient identity (sends a verification email to ${RECIPIENT})"
  aws sesv2 create-email-identity --email-identity "$RECIPIENT" --region "$REGION" >/dev/null
fi
RSTAT="$(aws sesv2 get-email-identity --email-identity "$RECIPIENT" --region "$REGION" \
  --query 'VerifiedForSendingStatus' --output text)"
echo "    recipient verified: ${RSTAT}"

# ---------------------------------------------------------------------------
# 5. IAM role for the Lambda
# ---------------------------------------------------------------------------
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[=] Role ${ROLE_NAME} exists"
else
  echo "[+] Creating role ${ROLE_NAME}"
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "[*] Waiting for role propagation"
  sleep 15
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name send-alert-mail \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ses:SendEmail\"],\"Resource\":[\"arn:aws:ses:${REGION}:${ACCT}:identity/${DOMAIN}\"]}]}"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# ---------------------------------------------------------------------------
# 6. Package + deploy the function
# ---------------------------------------------------------------------------
[ -f "$SRC" ] || { echo "[*] Fetching ${SRC}"; curl -fsSL -o "$SRC" "$RAW"; }
rm -f fn.zip && zip -q fn.zip "$SRC"

if aws lambda get-function --function-name "$FN_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Updating ${FN_NAME}"
  aws lambda update-function-code --function-name "$FN_NAME" --region "$REGION" \
    --zip-file fileb://fn.zip >/dev/null
  aws lambda wait function-updated --function-name "$FN_NAME" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN_NAME" --region "$REGION" \
    --environment "Variables={SENDER=${SENDER},RECIPIENT=${RECIPIENT}}" >/dev/null
else
  echo "[+] Creating ${FN_NAME}"
  aws lambda create-function --function-name "$FN_NAME" --region "$REGION" \
    --runtime python3.12 --role "$ROLE_ARN" --handler "${SRC%.py}.handler" \
    --timeout 15 --memory-size 128 --zip-file fileb://fn.zip \
    --environment "Variables={SENDER=${SENDER},RECIPIENT=${RECIPIENT}}" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$FN_NAME" --region "$REGION" 2>/dev/null || true
FN_ARN="$(aws lambda get-function --function-name "$FN_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)"

# ---------------------------------------------------------------------------
# 7. Let SNS invoke it, and subscribe it to the topic
# ---------------------------------------------------------------------------
aws lambda add-permission --function-name "$FN_NAME" --region "$REGION" \
  --statement-id sns-invoke --action lambda:InvokeFunction \
  --principal sns.amazonaws.com --source-arn "$TOPIC_ARN" >/dev/null 2>&1 \
  && echo "[+] Invoke permission added" || echo "[=] Invoke permission already present"

if aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$REGION" \
     --query 'Subscriptions[?Protocol==`lambda`].Endpoint' --output text | grep -q "$FN_ARN"; then
  echo "[=] Lambda already subscribed"
else
  aws sns subscribe --topic-arn "$TOPIC_ARN" --region "$REGION" \
    --protocol lambda --notification-endpoint "$FN_ARN" >/dev/null
  echo "[+] Lambda subscribed to topic"
fi

echo
echo "Done."
echo "  DKIM status:        $(aws sesv2 get-email-identity --email-identity "$DOMAIN" --region "$REGION" --query 'DkimAttributes.Status' --output text)"
echo "  Recipient verified: ${RSTAT}"
echo
echo "If recipient verified is PENDING, click the SES verification link sent to ${RECIPIENT}."
echo "Then test with:"
echo "  aws sns publish --region ${REGION} --topic-arn ${TOPIC_ARN} --subject 'SES pipeline test' --message 'hello from SES'"
