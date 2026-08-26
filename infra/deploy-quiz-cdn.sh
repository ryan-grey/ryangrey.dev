#!/usr/bin/env bash
# Point /api/quiz/* at the study-engine HTTP API.
#
# This edits the live distribution, so it takes the belt-and-braces route: fetch the current
# config, write it to a timestamped backup, append ONLY the new origin and behavior in
# Python, and push with --if-match so a concurrent edit fails loudly instead of clobbering.
#
# Deliberately no FunctionAssociations on this behavior. The viewer-request index rewrite
# maps directories to index.html; on an API path it would rewrite /api/quiz/state to
# /api/quiz/state/index.html and break every call -- the same trap documented for /api/ask.
set -euo pipefail

REGION=us-east-1
DIST=E34DKYH94YDAYR
API_HOST="${API_HOST:-b40vu13aqf.execute-api.us-east-1.amazonaws.com}"
ORIGIN_ID=quiz-lambda
PATTERN='/api/quiz/*'
BACKUP="/tmp/dist-config-$(date +%Y%m%d-%H%M%S).json"

aws cloudfront get-distribution-config --id "$DIST" --output json > "$BACKUP"
echo "[=] config backed up to $BACKUP"

python3 - "$BACKUP" "$API_HOST" "$ORIGIN_ID" "$PATTERN" <<'PY'
import json, sys
path, api_host, origin_id, pattern = sys.argv[1:5]
doc = json.load(open(path))
cfg = doc["DistributionConfig"]

origins = cfg["Origins"]["Items"]
if not any(o["Id"] == origin_id for o in origins):
    origins.append({
        "Id": origin_id, "DomainName": api_host, "OriginPath": "",
        "CustomHeaders": {"Quantity": 0},
        "CustomOriginConfig": {
            "HTTPPort": 80, "HTTPSPort": 443, "OriginProtocolPolicy": "https-only",
            "OriginSslProtocols": {"Quantity": 1, "Items": ["TLSv1.2"]},
            # 60s, not the 30s the chatbot uses: a quiz generation is a Bedrock round trip
            # with a much larger output than a chat reply.
            "OriginReadTimeout": 60, "OriginKeepaliveTimeout": 5},
        "ConnectionAttempts": 3, "ConnectionTimeout": 10,
        "OriginShield": {"Enabled": False}, "OriginAccessControlId": ""})
    cfg["Origins"]["Quantity"] = len(origins)
    print("  + origin", origin_id)
else:
    print("  = origin", origin_id, "already present")

behaviors = cfg.setdefault("CacheBehaviors", {"Quantity": 0, "Items": []}).setdefault("Items", [])
if not any(b["PathPattern"] == pattern for b in behaviors):
    behaviors.append({
        "PathPattern": pattern, "TargetOriginId": origin_id,
        "TrustedSigners": {"Enabled": False, "Quantity": 0},
        "TrustedKeyGroups": {"Enabled": False, "Quantity": 0},
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {"Quantity": 7,
            "Items": ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"],
            "CachedMethods": {"Quantity": 2, "Items": ["HEAD", "GET"]}},
        "SmoothStreaming": False, "Compress": False,
        "LambdaFunctionAssociations": {"Quantity": 0},
        "FunctionAssociations": {"Quantity": 0},
        "FieldLevelEncryptionId": "",
        # CachingDisabled + AllViewerExceptHostHeader, same managed policies as /api/ask.
        # AllViewer matters: without it CloudFront strips the Authorization header and every
        # authenticated call fails with a 401 that looks like a Cognito problem.
        "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
        "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
        "GrpcConfig": {"Enabled": False}})
    cfg["CacheBehaviors"]["Quantity"] = len(behaviors)
    print("  + behavior", pattern)
else:
    print("  = behavior", pattern, "already present")

json.dump(cfg, open("/tmp/quiz-dist-config.json", "w"))
PY

ETAG="$(python3 -c "import json;print(json.load(open('$BACKUP'))['ETag'])")"
aws cloudfront update-distribution --id "$DIST" --if-match "$ETAG" \
  --distribution-config "file:///tmp/quiz-dist-config.json" \
  --query 'Distribution.Status' --output text
echo "[+] update submitted (propagation ~1-3 min)"
