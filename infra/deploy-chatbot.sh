#!/usr/bin/env bash
#
# Deploys the "Ask about Ryan" chatbot Lambda and the HTTP API in front of it.
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
# Resolved from the active credentials so no account ID lives in the repo.
ACCT="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCT}:role/ryangrey-chatbot-role"
TABLE="ryangrey-chatbot-ratelimit"
TOPIC="arn:aws:sns:us-east-1:${ACCT}:ryangrey-dev-alerts"
CHAT_MODEL="us.amazon.nova-lite-v1:0"
EMBED_MODEL="amazon.titan-embed-text-v2:0"
API_NAME="ryangrey-chatbot-api"
ORIGIN="https://ryangrey.dev"
DISTRIBUTION_ID="E34DKYH94YDAYR"
ACCOUNT="$(echo "$ROLE_ARN" | cut -d: -f5)"

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

# Record which corpus is now actually inside the function.
#
# The corpus ships in the Lambda zip, but `aws s3 sync` in the site workflow
# excludes infra/*, so committing a rebuilt corpus.json deploys nothing to the
# bot. On 2026-09-03 that left the committed corpus one version ahead of the
# live one with every guard still green -- the site deploy had no way to know
# the chatbot had been left behind.
#
# check-corpus-drift.py compares corpus.json against this stamp, so "rebuilt
# but never deployed" is now a build error. Written only after the update has
# been waited on, so a failed deploy cannot leave a stamp claiming success.
shasum -a 256 "${HERE}/corpus.json" | cut -d' ' -f1 > "${HERE}/corpus.deployed.sha256"
echo "[+] Stamped deployed corpus: $(cut -c1-12 < "${HERE}/corpus.deployed.sha256")..."

# Reserved concurrency bounds burst rate. Defence-in-depth only: the hard
# budget bound is the global monthly counter in DynamoDB, which the function
# enforces per-invocation regardless of concurrency. Non-fatal either way.
#
# The reason it fails is printed rather than guessed at. It used to say the
# caller lacked lambda:PutFunctionConcurrency, which on 31 Aug 2026 sent a
# perfectly well-permitted caller looking for a missing IAM statement: the
# actual error was InvalidParameterValueException, because this account's total
# concurrency limit is 10 and AWS refuses to let unreserved concurrency fall
# below 10 - so reserving any at all is impossible here, for anyone.
if CONC_ERR=$(aws lambda put-function-concurrency --function-name "$FN" --region "$REGION" \
     --reserved-concurrent-executions 3 2>&1 >/dev/null); then
  echo "[+] Reserved concurrency: 3"
else
  echo "[!] Could not set reserved concurrency. AWS said:"
  echo "    ${CONC_ERR##*: }"
  echo "    Budget is still bounded by the GLOBAL_MONTHLY counter in DynamoDB."
fi

# An HTTP API, NOT a Lambda Function URL.
#
# A Function URL would have to be AWS_IAM (a public one is blocked at the URL
# auth layer on this account) and CloudFront can only reach that by signing
# SigV4 through OAC -- a second auth surface in the path for no gain. An HTTP
# API is an ordinary custom origin: CloudFront proxies /api/ask straight to
# it, so the browser call stays same-origin (no CORS preflight, and the CSP
# for /ask keeps connect-src 'self'), and the function's resource policy names
# this API as the only permitted caller.
#
# The execute-api endpoint is reachable directly, bypassing CloudFront. That
# is deliberate: the rate limits live in the handler and run per-invocation
# regardless of how the request arrived, so the budget bound does not depend
# on traffic going through the CDN.
FN_ARN="$(aws lambda get-function --function-name "$FN" --region "$REGION" \
  --query Configuration.FunctionArn --output text)"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"

if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  echo "[+] Creating HTTP API ${API_NAME}"
  # --target builds the AWS_PROXY integration, the $default route and an
  # auto-deploying $default stage in one call.
  API_ID="$(aws apigatewayv2 create-api --region "$REGION" --name "$API_NAME" \
    --protocol-type HTTP --target "$FN_ARN" --query ApiId --output text)"
else
  echo "[=] HTTP API ${API_NAME} exists (${API_ID})"
fi

# Only this API may invoke the function.
aws lambda add-permission --function-name "$FN" --region "$REGION" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*" >/dev/null 2>&1 \
  && echo "[+] API Gateway invoke permission added" \
  || echo "[=] API Gateway invoke permission already present"

# The distribution's origin is configured by hand; a mismatch here means
# /api/ask is proxying to some other API and no amount of Lambda deploying
# will fix it. Non-fatal, but say so loudly.
API_HOST="${API_ID}.execute-api.${REGION}.amazonaws.com"
CF_HOST="$(aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" \
  --query "DistributionConfig.Origins.Items[?Id=='chatbot-lambda'].DomainName | [0]" \
  --output text 2>/dev/null || echo unknown)"
if [ "$CF_HOST" = "$API_HOST" ]; then
  echo "[=] CloudFront origin points at this API"
else
  echo "[!] CloudFront origin is ${CF_HOST}, expected ${API_HOST}"
fi

rm -rf "$TMP"
echo
echo "Endpoint (public):  ${ORIGIN}/api/ask"
echo "Origin (HTTP API):  https://${API_HOST}"
