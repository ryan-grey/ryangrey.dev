#!/usr/bin/env bash
#
# Map the origin's 403 to a branded 404 page.
#
# An S3 origin behind an origin access control has no ListBucket, so a missing
# object comes back 403 AccessDenied rather than 404 NoSuchKey -- and raw, as an
# XML error document. This turns that into the site's own 404 page with an
# honest status code.
#
# ---------------------------------------------------------------------------
# Two things here are deliberate and easy to "fix" wrongly
#
# 1. ErrorCachingMinTTL is 10, not the 300 CloudFront defaults to. Custom error
#    responses are cached, and at 300s CloudFront would answer ~30x more probes
#    from cache without ever touching the origin. The origin access logs -- the
#    only 4xx visibility this distribution has, since CloudFront's own logging
#    needs a paid plan -- would go quiet and look like the problem had been
#    fixed. 10s matches the default error caching this distribution had before,
#    so the measurement keeps working.
#
# 2. Only 403 is mapped: missing objects on the private S3 REST origin return 403.
# ---------------------------------------------------------------------------
#
# Idempotent: safe to re-run.
#
# Usage:  AWS_PROFILE=infra ./infra/deploy-error-page.sh

set -euo pipefail

DISTRIBUTION_ID="E34DKYH94YDAYR"
PAGE="/404.html"
TTL=10

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "==> Checking $PAGE is actually served"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://ryangrey.dev${PAGE}")
[ "$CODE" = "200" ] || {
    echo "!! ${PAGE} returns ${CODE}. Deploy it before pointing errors at it," >&2
    echo "   or every 403 becomes a 403 for the error page as well." >&2
    exit 1; }
echo "    200"

echo "==> Fetching distribution config"
aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > "$WORK/dist.json"
ETAG=$(python3 -c "import json;print(json.load(open('$WORK/dist.json'))['ETag'])")

python3 - "$WORK/dist.json" "$WORK/config.json" "$PAGE" "$TTL" <<'PY'
import json, sys
src, dst, page, ttl = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
config = json.load(open(src))["DistributionConfig"]

wanted = {
    "ErrorCode": 403,
    "ResponsePagePath": page,
    "ResponseCode": "404",
    "ErrorCachingMinTTL": ttl,
}

existing = config.get("CustomErrorResponses", {}).get("Items", [])
# Replace any existing rule for the same code, keep every other rule untouched.
items = [i for i in existing if i.get("ErrorCode") != wanted["ErrorCode"]] + [wanted]
config["CustomErrorResponses"] = {"Quantity": len(items), "Items": items}

json.dump(config, open(dst, "w"))
print(f"    {len(items)} custom error response(s): "
      + ", ".join(f"{i['ErrorCode']}->{i.get('ResponseCode')}" for i in items))
PY

echo "==> Updating distribution"
aws cloudfront update-distribution --id "$DISTRIBUTION_ID" \
    --if-match "$ETAG" --distribution-config "file://$WORK/config.json" \
    --query 'Distribution.Status' --output text

echo
echo "Deploying — takes a few minutes to reach every edge. Then verify:"
echo "    curl -s -o /dev/null -w '%{http_code}\\n' https://ryangrey.dev/no-such-page"
echo "    expect 404, and an HTML body rather than S3's AccessDenied XML."
