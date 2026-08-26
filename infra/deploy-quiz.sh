#!/usr/bin/env bash
# Deploy the AIF Study Engine API: Lambda + HTTP API fronted by a Cognito JWT authorizer.
#
# The authorizer is the point. Quiz generation invokes Bedrock, which costs money, so the
# gateway rejects unauthenticated calls before any code runs. Routes are attached to it
# explicitly -- there is deliberately no $default route, so an unrouted path 404s rather
# than falling through to the handler.
#
# Idempotent: safe to re-run. Creates what is missing, updates what exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION=us-east-1
ACCOUNT=<AWS_ACCOUNT_ID>
FN=ryangrey-quiz
ROLE=arn:aws:iam::<AWS_ACCOUNT_ID>:role/ryangrey-quiz-role
API_NAME=ryangrey-quiz-api
POOL_ID="${POOL_ID:-us-east-1_U86zGAmic}"
CLIENT_ID="${CLIENT_ID:-2han2rpqbpv47m7vhju7nfb9mo}"
ISSUER="https://cognito-idp.${REGION}.amazonaws.com/${POOL_ID}"
ALLOWED_SUB="${ALLOWED_SUB:-}"

echo "==> Scope self-test (blocks the deploy on failure)"
python3 "$ROOT/infra/check-quiz-scope.py"

echo "==> Packaging"
TMP="$(mktemp -d)"
cp "$ROOT/infra/quiz/handler.py" "$TMP/"
cp "$ROOT/infra/aif-c01-course.json" "$TMP/aif-c01-course.json"
( cd "$TMP" && zip -qr package.zip . )
echo "    package: $(du -h "$TMP/package.zip" | cut -f1)"

# JSON form, not shorthand: an empty ALLOWED_SUB is valid (the pool has exactly one
# admin-created user) and shorthand cannot express an empty value.
ENV="$(printf '{"Variables":{"QUIZ_TABLE":"ryangrey-quiz","CHAT_MODEL":"us.amazon.nova-lite-v1:0","ALLOWED_SUB":"%s"}}' "$ALLOWED_SUB")"

if aws lambda get-function --function-name "$FN" --region "$REGION" >/dev/null 2>&1; then
  echo "[=] Updating $FN"
  aws lambda update-function-code --function-name "$FN" --region "$REGION" \
    --zip-file "fileb://$TMP/package.zip" >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$FN" --region "$REGION" \
    --environment "$ENV" --timeout 60 --memory-size 512 >/dev/null
  aws lambda wait function-updated --function-name "$FN" --region "$REGION"
else
  echo "[+] Creating $FN"
  aws lambda create-function --function-name "$FN" --region "$REGION" \
    --runtime python3.12 --handler handler.handler --role "$ROLE" \
    --zip-file "fileb://$TMP/package.zip" \
    --environment "$ENV" --timeout 60 --memory-size 512 >/dev/null
  aws lambda wait function-active-v2 --function-name "$FN" --region "$REGION"
fi

# Everything below touches API Gateway, which ryan-cli can READ but not write. The API,
# authorizer and routes are admin-owned (created from the CloudShell block in
# infra/README-quiz-iam.md) and are already correct, so this is a VERIFICATION pass rather
# than a reconcile: it reports drift loudly instead of attempting updates that can only ever
# be denied. The Lambda code above is what this script actually ships.
FN_ARN="$(aws lambda get-function --function-name "$FN" --region "$REGION" \
  --query Configuration.FunctionArn --output text)"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || true)"
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  echo "[skip] API Gateway not readable here — Lambda code is deployed, nothing else to do."
  rm -rf "$TMP"
  exit 0
fi

echo "==> Verifying admin-managed API Gateway wiring (${API_ID})"
DRIFT=0

AUTH_COUNT="$(aws apigatewayv2 get-authorizers --region "$REGION" --api-id "$API_ID" \
  --query "length(Items[?Name=='cognito-jwt'])" --output text 2>/dev/null || echo 0)"
if [ "$AUTH_COUNT" = "1" ]; then
  echo "    [ok] cognito-jwt authorizer present"
else
  echo "    [!!] cognito-jwt authorizer MISSING — /api/quiz would be open to the internet"
  DRIFT=1
fi

for RK in "GET /api/quiz/state" "POST /api/quiz/progress" "POST /api/quiz/generate" \
          "POST /api/quiz/answer" "POST /api/quiz/session"; do
  AUTHZ="$(aws apigatewayv2 get-routes --region "$REGION" --api-id "$API_ID" \
    --query "Items[?RouteKey=='${RK}'].AuthorizationType | [0]" --output text 2>/dev/null || echo None)"
  case "$AUTHZ" in
    JWT)  echo "    [ok] ${RK}" ;;
    None) echo "    [!!] ${RK} has NO authorizer — it would run unauthenticated"; DRIFT=1 ;;
    *)    echo "    [!!] ${RK} missing from the API"; DRIFT=1 ;;
  esac
done

rm -rf "$TMP"
echo
echo "API host:  https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo "Issuer:    ${ISSUER}"
[ "$DRIFT" = "0" ] || { echo; echo "Gateway drift detected — fix in CloudShell as admin."; exit 1; }
