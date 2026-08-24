#!/usr/bin/env bash
#
# Creates/updates the CloudFront viewer-response function that adds security
# headers, publishes it, and associates it with the distribution.
#
# Idempotent: safe to re-run after editing cloudfront-security-headers.js.
#
# Usage:  DISTRIBUTION_ID=<id> ./infra/deploy-security-headers.sh

set -euo pipefail

FN_NAME="ryangrey-security-headers"
SRC="$(dirname "$0")/cloudfront-security-headers.js"
RUNTIME="cloudfront-js-2.0"

: "${DISTRIBUTION_ID:?Set DISTRIBUTION_ID=... before running}"
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create or update the function
# ---------------------------------------------------------------------------
if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
  ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
  echo "[=] Updating $FN_NAME"
  aws cloudfront update-function --name "$FN_NAME" --if-match "$ETAG" \
    --function-config "{\"Comment\":\"Adds security headers\",\"Runtime\":\"${RUNTIME}\"}" \
    --function-code "fileb://${SRC}" >/dev/null
else
  echo "[+] Creating $FN_NAME"
  aws cloudfront create-function --name "$FN_NAME" \
    --function-config "{\"Comment\":\"Adds security headers\",\"Runtime\":\"${RUNTIME}\"}" \
    --function-code "fileb://${SRC}" >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. Test before publishing -- a broken CSP fails silently in production
# ---------------------------------------------------------------------------
ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
cat > /tmp/rhp-event.json <<'JSON'
{"version":"1.0","context":{"eventType":"viewer-response"},
 "viewer":{"ip":"1.2.3.4"},
 "request":{"method":"GET","uri":"/","headers":{},"cookies":{},"querystring":{}},
 "response":{"statusCode":200,"statusDescription":"OK",
   "headers":{"content-type":{"value":"text/html"}},"cookies":{}}}
JSON
echo "[*] Testing function output"
aws cloudfront test-function --name "$FN_NAME" --if-match "$ETAG" \
  --stage DEVELOPMENT --event-object fileb:///tmp/rhp-event.json \
  --query 'TestResult.FunctionOutput' --output text \
  | python3 -c 'import sys,json; h=json.load(sys.stdin)["response"]["headers"]; [print("      "+k) for k in sorted(h)]'

# ---------------------------------------------------------------------------
# 3. Publish to LIVE
# ---------------------------------------------------------------------------
echo "[+] Publishing"
FN_ARN="$(aws cloudfront publish-function --name "$FN_NAME" --if-match "$ETAG" \
  --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)"

# ---------------------------------------------------------------------------
# 4. Associate with the distribution (no-op if already attached)
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > "${TMP}/dist.json"
D_ETAG="$(python3 -c "import json;print(json.load(open('${TMP}/dist.json'))['ETag'])")"

if python3 - "$TMP" "$FN_ARN" <<'PY'
import json,sys
tmp,arn=sys.argv[1],sys.argv[2]
cfg=json.load(open(f"{tmp}/dist.json"))["DistributionConfig"]
b=cfg["DefaultCacheBehavior"]
cur=b.get("FunctionAssociations",{}).get("Items",[])
if any(i.get("FunctionARN")==arn and i.get("EventType")=="viewer-response" for i in cur):
    sys.exit(1)                      # already associated -> skip update
b["FunctionAssociations"]={"Quantity":1,"Items":[
    {"FunctionARN":arn,"EventType":"viewer-response"}]}
json.dump(cfg,open(f"{tmp}/new.json","w"))
PY
then
  echo "[+] Associating with $DISTRIBUTION_ID"
  aws cloudfront update-distribution --id "$DISTRIBUTION_ID" \
    --distribution-config "file://${TMP}/new.json" --if-match "$D_ETAG" \
    --query 'Distribution.Status' --output text
else
  echo "[=] Already associated"
fi
rm -rf "$TMP"

echo
echo "Done. Verify once deployed:"
echo "  curl -sI https://ryangrey.dev/ | grep -iE 'content-security|strict-transport|x-frame'"
