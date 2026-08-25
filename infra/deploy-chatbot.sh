#!/usr/bin/env bash
#
# Deploys the "Ask about Ryan" chatbot Lambda and its Function URL.
#
# Packages handler.py together with the generated corpus (infra/corpus.json),
# so the retrieval index ships inside the function -- no vector database, no
# standing cost. Rebuild the corpus first if the site or CV changed:
#   python3 infra/build-corpus.py
#
# Idempotent: safe to re-run. Creates on first run, updates thereafter.
#
# Usage:  ./infra/deploy-chatbot.sh

set -euo pipefail

REGION="us-east-1"
FN="ryangrey-chatbot"
ROLE_ARN="arn:aws:iam::<AWS_ACCOUNT_ID>:role/ryangrey-chatbot-role"
TABLE="ryangrey-chatbot-ratelimit"
TOPIC="arn:aws:sns:us-east-1:<AWS_ACCOUNT_ID>:ryangrey-dev-alerts"
CHAT_MODEL="us.amazon.nova-lite-v1:0"
EMBED_MODEL="amazon.titan-embed-text-v2:0"
ORIGIN="https://ryangrey.dev"

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "${HERE}/corpus.json" ] || { echo "missing corpus.json -- run build-corpus.py" >&2; exit 1; }

ENVVARS="Variables={CHAT_MODEL=${CHAT_MODEL},EMBED_MODEL=${EMBED_MODEL},TABLE=${TABLE},ALERT_TOPIC=${TOPIC},ALLOWED_ORIGIN=${ORIGIN},PER_IP_HOURLY=10,GLOBAL_MONTHLY=3000}"

TMP="$(mktemp -d)"
cp "${HERE}/chatbot/handler.py" "${HERE}/corpus.json" "$TMP/"
(cd "$TMP" && zip -q fn.zip handler.py corpus.json)
echo "package: $(du -h "$TMP/fn.zip" | cut -f1)"

if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Updating ${FN}"
  aws lambda update-function-code --function-name "$FN" --region "$REGION" \
    --zip-file "fileb://$TMP/fn.zip" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --timeout 30 --memory-size 256 --environment "$ENVVARS" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  echo "[+] Creating ${FN}"
  aws lambda create-function --function-name "$FN" --region "$REGION" \
    --runtime python3.12 --role "$ROLE_ARN" --handler handler.handler \
    --timeout 30 --memory-size 256 --environment "$ENVVARS" \
    --zip-file "fileb://$TMP/fn.zip" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FN" --region "$REGION"
fi

# Reserved concurrency bounds burst rate. Defence-in-depth only: the hard
# budget bound is the global monthly counter in DynamoDB, which the function
# enforces per-invocation regardless of concurrency. Non-fatal if the caller
# lacks lambda:PutFunctionConcurrency.
if aws lambda put-function-concurrency --function-name "$FN" --region "$REGION" \
     --reserved-concurrent-executions 3 >/dev/null 2>&1; then
  echo "[+] Reserved concurrency: 3"
else
  echo "[!] Could not set reserved concurrency (lambda:PutFunctionConcurrency denied)."
  echo "    Budget is still bounded by the GLOBAL_MONTHLY counter in DynamoDB."
fi

if aws lambda get-function-url-config --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Function URL exists"
else
  echo "[+] Creating Function URL"
  aws lambda create-function-url-config --function-name "$FN" --region "$REGION" \
    --auth-type NONE \
    --cors "AllowOrigins=${ORIGIN},AllowMethods=POST,AllowHeaders=content-type,MaxAge=86400" >/dev/null
  aws lambda add-permission --function-name "$FN" --region "$REGION" \
    --statement-id public-function-url --action lambda:InvokeFunctionUrl \
    --principal "*" --function-url-auth-type NONE >/dev/null
fi

rm -rf "$TMP"
URL="$(aws lambda get-function-url-config --function-name "$FN" --region "$REGION" --query FunctionUrl --output text)"
echo
echo "Function URL: ${URL}"
