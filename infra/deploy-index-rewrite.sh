#!/usr/bin/env bash
#
# Creates/updates the CloudFront viewer-request function that rewrites
# directory URIs to their index.html, publishes it, and associates it with
# the distribution's DEFAULT cache behavior.
#
# Idempotent: safe to re-run after editing cloudfront-index-rewrite.js.
#
# DO NOT associate this function with the /api/ask cache behavior. It would
# rewrite that path to /api/ask/index.html and break the chatbot. The
# association below is scoped to DefaultCacheBehavior for exactly that reason.
#
# Usage:  DISTRIBUTION_ID=<id> ./infra/deploy-index-rewrite.sh

set -euo pipefail

FN_NAME="ryangrey-index-rewrite"
SRC="$(dirname "$0")/cloudfront-index-rewrite.js"
RUNTIME="cloudfront-js-2.0"
COMMENT="Rewrites directory URIs to index.html"

: "${DISTRIBUTION_ID:?Set DISTRIBUTION_ID=... before running}"
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create or update the function
# ---------------------------------------------------------------------------
if aws cloudfront describe-function --name "$FN_NAME" >/dev/null 2>&1; then
  ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
  echo "[=] Updating $FN_NAME"
  aws cloudfront update-function --name "$FN_NAME" --if-match "$ETAG" \
    --function-config "{\"Comment\":\"${COMMENT}\",\"Runtime\":\"${RUNTIME}\"}" \
    --function-code "fileb://${SRC}" >/dev/null
else
  echo "[+] Creating $FN_NAME"
  aws cloudfront create-function --name "$FN_NAME" \
    --function-config "{\"Comment\":\"${COMMENT}\",\"Runtime\":\"${RUNTIME}\"}" \
    --function-code "fileb://${SRC}" >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. Test before publishing -- a bad rewrite 403s the whole site
#
# The expectations below are the function's contract. A rewrite that sends a
# real file through the directory branch (or leaves a directory alone) breaks
# silently in production, so assert instead of eyeballing.
# ---------------------------------------------------------------------------
ETAG="$(aws cloudfront describe-function --name "$FN_NAME" --query ETag --output text)"
echo "[*] Testing rewrites"
FAIL=0
while IFS='|' read -r IN WANT; do
  cat > /tmp/idx-event.json <<JSON
{"version":"1.0","context":{"eventType":"viewer-request"},
 "viewer":{"ip":"1.2.3.4"},
 "request":{"method":"GET","uri":"${IN}","headers":{},"cookies":{},"querystring":{}}}
JSON
  GOT="$(aws cloudfront test-function --name "$FN_NAME" --if-match "$ETAG" \
    --stage DEVELOPMENT --event-object fileb:///tmp/idx-event.json \
    --query 'TestResult.FunctionOutput' --output text \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["request"]["uri"])')"
  if [ "$GOT" = "$WANT" ]; then
    echo "      ok   ${IN} -> ${GOT}"
  else
    echo "      FAIL ${IN} -> ${GOT} (expected ${WANT})"
    FAIL=1
  fi
done <<'CASES'
/|/index.html
/ask|/ask/index.html
/ask/|/ask/index.html
/index.html|/index.html
/ryan-grey-cv.pdf|/ryan-grey-cv.pdf
/ask/app.js|/ask/app.js
CASES
rm -f /tmp/idx-event.json
[ "$FAIL" -eq 0 ] || { echo "Refusing to publish: rewrite contract broken." >&2; exit 1; }

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

if python3 - "$TMP" "$FN_ARN" viewer-request <<'PY'
import json,sys
tmp,arn,evt=sys.argv[1],sys.argv[2],sys.argv[3]
cfg=json.load(open(f"{tmp}/dist.json"))["DistributionConfig"]
b=cfg["DefaultCacheBehavior"]
cur=b.get("FunctionAssociations",{}).get("Items",[])
if any(i.get("FunctionARN")==arn and i.get("EventType")==evt for i in cur):
    sys.exit(1)                      # already associated -> skip update
# Keep associations for OTHER event types. Writing a bare one-item list here
# would silently DETACH the sibling function on the other event type.
items=[i for i in cur if i.get("EventType")!=evt]
items.append({"FunctionARN":arn,"EventType":evt})
b["FunctionAssociations"]={"Quantity":len(items),"Items":items}
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
echo "  for p in / /ask /ask/ /ask/index.html; do"
echo "    curl -sS -o /dev/null -w \"%{http_code} \$p\\n\" \"https://ryangrey.dev\$p\"; done"
