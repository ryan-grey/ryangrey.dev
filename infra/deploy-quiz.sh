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

FN_ARN="$(aws lambda get-function --function-name "$FN" --region "$REGION" \
  --query Configuration.FunctionArn --output text)"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
  echo "[+] Creating HTTP API ${API_NAME}"
  API_ID="$(aws apigatewayv2 create-api --region "$REGION" --name "$API_NAME" \
    --protocol-type HTTP --query ApiId --output text)"
  aws apigatewayv2 create-stage --region "$REGION" --api-id "$API_ID" \
    --stage-name '$default' --auto-deploy >/dev/null
else
  echo "[=] HTTP API ${API_NAME} exists (${API_ID})"
fi

INT_ID="$(aws apigatewayv2 get-integrations --region "$REGION" --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='${FN_ARN}'].IntegrationId | [0]" --output text)"
if [ "$INT_ID" = "None" ] || [ -z "$INT_ID" ]; then
  INT_ID="$(aws apigatewayv2 create-integration --region "$REGION" --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$FN_ARN" \
    --payload-format-version 2.0 --query IntegrationId --output text)"
  echo "[+] Integration $INT_ID"
else
  echo "[=] Integration $INT_ID"
fi

AUTH_ID="$(aws apigatewayv2 get-authorizers --region "$REGION" --api-id "$API_ID" \
  --query "Items[?Name=='cognito-jwt'].AuthorizerId | [0]" --output text)"
if [ "$AUTH_ID" = "None" ] || [ -z "$AUTH_ID" ]; then
  AUTH_ID="$(aws apigatewayv2 create-authorizer --region "$REGION" --api-id "$API_ID" \
    --name cognito-jwt --authorizer-type JWT \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Issuer=${ISSUER},Audience=${CLIENT_ID}" \
    --query AuthorizerId --output text)"
  echo "[+] JWT authorizer $AUTH_ID"
else
  aws apigatewayv2 update-authorizer --region "$REGION" --api-id "$API_ID" \
    --authorizer-id "$AUTH_ID" \
    --jwt-configuration "Issuer=${ISSUER},Audience=${CLIENT_ID}" >/dev/null
  echo "[=] JWT authorizer $AUTH_ID (config refreshed)"
fi

# Explicit routes only. No $default: an unknown path must 404 at the gateway.
for RK in "GET /api/quiz/state" "POST /api/quiz/progress" "POST /api/quiz/generate" \
          "POST /api/quiz/answer" "POST /api/quiz/session"; do
  EXISTING="$(aws apigatewayv2 get-routes --region "$REGION" --api-id "$API_ID" \
    --query "Items[?RouteKey=='${RK}'].RouteId | [0]" --output text)"
  if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
    aws apigatewayv2 create-route --region "$REGION" --api-id "$API_ID" \
      --route-key "$RK" --target "integrations/${INT_ID}" \
      --authorization-type JWT --authorizer-id "$AUTH_ID" >/dev/null
    echo "[+] route  $RK"
  else
    aws apigatewayv2 update-route --region "$REGION" --api-id "$API_ID" \
      --route-id "$EXISTING" --target "integrations/${INT_ID}" \
      --authorization-type JWT --authorizer-id "$AUTH_ID" >/dev/null
    echo "[=] route  $RK"
  fi
done

aws lambda add-permission --function-name "$FN" --region "$REGION" \
  --statement-id apigw-invoke --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*" >/dev/null 2>&1 \
  && echo "[+] invoke permission added" || echo "[=] invoke permission present"

rm -rf "$TMP"
API_HOST="${API_ID}.execute-api.${REGION}.amazonaws.com"
echo
echo "API host:  https://${API_HOST}"
echo "Issuer:    ${ISSUER}"
echo "Audience:  ${CLIENT_ID}"
