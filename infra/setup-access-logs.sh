#!/usr/bin/env bash
#
# Access logging, so the 4xx rate is a measurement rather than an argument.
#
# Context: the site's 4xx rate sits around 59%. An S3 origin behind an origin
# access control returns 403 for anything absent -- no ListBucket, so
# AccessDenied rather than NoSuchKey -- which means every request for a file that
# was never there counts. robots.txt and sitemap.xml were two such files and are
# now real. What remains is BELIEVED to be unsolicited probing, believed from
# probing paths by hand. This is what turns that into a fact.
#
# ---------------------------------------------------------------------------
# This logs the ORIGIN, not the edge, and that is not the first choice
#
# CloudFront access logging is unavailable on this distribution. Both paths are
# refused, and the second refusal hides behind the first, so in order:
#
#   1. Standard logging v2 (the CloudWatch Logs vended-delivery API):
#        PutDeliverySource: You can't enable standard access log delivery for a
#        distribution on a Free plan tier. Upgrade to a paid plan and try again.
#
#   2. Legacy logging (the `Logging` block in the distribution config):
#        First:  The S3 bucket that you specified for CloudFront logs does not
#                enable ACL access
#        Then, once the bucket had ACLs:
#                Distributions with the Free pricing plan can't have the
#                following features: Standard logging
#
# The ACL complaint comes from an earlier validation gate than the plan check, so
# legacy logging briefly looks permitted when it is not. It is not. Do not spend
# an afternoon re-discovering this -- CloudFront logging needs a paid pricing
# plan, full stop, and a paid plan costs more per month than the entire budget
# this site is monitored against.
#
# So: S3 server access logging on the ORIGIN bucket instead. It is free, it is
# not plan-gated, and it happens to suit this specific question well. What we
# want to know is which paths are 403ing, and a 403 for a missing key is exactly
# the request that reaches the origin: there are no custom error responses on
# this distribution, so 403s are cached for only the default 10 seconds and
# essentially every distinct probe lands on S3.
#
# KNOW THE LIMIT: this cannot see anything CloudFront served from cache. It is a
# census of origin requests, not of viewer requests. Do not read a hit count here
# as site traffic -- the 4xx picture it gives is sound, the 2xx picture is not.
# ---------------------------------------------------------------------------
#
# Idempotent: safe to re-run.
#
# Usage:  AWS_PROFILE=infra ./infra/setup-access-logs.sh

set -euo pipefail

ACCOUNT="<AWS_ACCOUNT_ID>"
REGION="us-east-1"
SITE_BUCKET="ryangrey.dev"
BUCKET="ryangrey-dev-logs"
PREFIX="s3-origin/"
RETAIN_DAYS=30

echo "==> Bucket s3://${BUCKET}"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "    exists"
else
    # us-east-1 is the one region that rejects a LocationConstraint.
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    echo "    created"
fi

echo "==> Public access fully blocked"
aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=true >/dev/null
# BlockPublicPolicy is false only so the service policy below can be written. It
# grants one named AWS service principal and no public principal, and
# RestrictPublicBuckets=true means a public policy could not take effect anyway.

echo "==> ACLs off (BucketOwnerEnforced)"
# Deliberately back to the modern default. An earlier revision of this script set
# ObjectWriter because legacy CloudFront logging delivers over ACLs -- that turned
# out to be unreachable on a Free plan, so the concession bought nothing and is
# reverted. S3 server access logging authorises by bucket policy and needs no ACLs.
aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null

echo "==> Default encryption (SSE-S3)"
# AES256 rather than KMS deliberately: KMS would bill per request on every log
# object written. These logs hold request paths and viewer IPs, not credentials.
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null

echo "==> Lifecycle: expire after ${RETAIN_DAYS} days"
# Bounds cost to a constant, and bounds how long viewer IPs are kept, which is
# the more important of the two reasons.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration "{
  \"Rules\": [{
    \"ID\": \"expire-access-logs\",
    \"Status\": \"Enabled\",
    \"Filter\": {\"Prefix\": \"${PREFIX}\"},
    \"Expiration\": {\"Days\": ${RETAIN_DAYS}},
    \"AbortIncompleteMultipartUpload\": {\"DaysAfterInitiation\": 7}
  }]
}" >/dev/null

echo "==> Bucket policy for the S3 logging service"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"S3ServerAccessLogsPolicy\",
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"logging.s3.amazonaws.com\"},
    \"Action\": \"s3:PutObject\",
    \"Resource\": \"arn:aws:s3:::${BUCKET}/${PREFIX}*\",
    \"Condition\": {
      \"StringEquals\": {\"aws:SourceAccount\": \"${ACCOUNT}\"},
      \"ArnLike\": {\"aws:SourceArn\": \"arn:aws:s3:::${SITE_BUCKET}\"}
    }
  }]
}" >/dev/null

echo "==> Enabling server access logging on s3://${SITE_BUCKET}"
aws s3api put-bucket-logging --bucket "$SITE_BUCKET" --bucket-logging-status "{
  \"LoggingEnabled\": {
    \"TargetBucket\": \"${BUCKET}\",
    \"TargetPrefix\": \"${PREFIX}\"
  }
}" >/dev/null
aws s3api get-bucket-logging --bucket "$SITE_BUCKET" \
    --query 'LoggingEnabled.[TargetBucket,TargetPrefix]' --output text

echo
echo "Done. Logs land under s3://${BUCKET}/${PREFIX}"
echo "S3 delivers on a best-effort delay -- usually within a couple of hours."
echo "Then:  ./infra/analyse-access-logs.sh"
