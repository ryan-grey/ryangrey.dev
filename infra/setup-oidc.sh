#!/usr/bin/env bash
#
# One-time setup: lets GitHub Actions deploy this site to S3/CloudFront
# without any stored AWS access keys.
#
# Creates:
#   1. An IAM OIDC identity provider trusting GitHub's token issuer
#   2. An IAM role that ONLY this repo, on ONLY this branch, may assume
#   3. A least-privilege policy on that role (write this bucket, invalidate
#      this distribution — nothing else)
#
# Requires credentials with IAM admin rights. Idempotent: safe to re-run.
#
# Usage:  ./scripts/setup-oidc.sh

set -euo pipefail

GITHUB_ORG="ryan-grey"
GITHUB_REPO="ryangrey.dev"
BRANCH="main"
BUCKET="ryangrey.dev"
ROLE_NAME="github-actions-ryangrey-dev-deploy"
POLICY_NAME="deploy-site"
REGION="us-east-1"

: "${DISTRIBUTION_ID:?Set DISTRIBUTION_ID=... before running (your CloudFront distribution ID)}"

ISSUER="token.actions.githubusercontent.com"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${ISSUER}"

# GitHub issues an *immutable* subject claim: owner and repo names carry their
# numeric database IDs, e.g.
#   repo:owner@146499233/repo@1345403610:ref:refs/heads/main
# rather than the documented plain form. The IDs make the subject survive a
# rename, and stop anyone who deletes and re-registers the name from
# inheriting its trust. They must be resolved, not assumed.
OWNER_ID="$(curl -fsSL "https://api.github.com/users/${GITHUB_ORG}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
REPO_ID="$(curl -fsSL "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
SUBJECT="repo:${GITHUB_ORG}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID}:ref:refs/heads/${BRANCH}"

echo "Account:      ${ACCOUNT_ID}"
echo "Repo:         ${GITHUB_ORG}/${GITHUB_REPO}"
echo "Branch:       ${BRANCH}"
echo "Role:         ${ROLE_NAME}"
echo "Subject:      ${SUBJECT}"
echo

# ---------------------------------------------------------------------------
# 1. OIDC identity provider
# ---------------------------------------------------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "[=] OIDC provider already exists"
else
  echo "[+] Creating OIDC provider for ${ISSUER}"
  # AWS validates GitHub's certificate against its own trust store, so the
  # thumbprint below is vestigial — the API still requires the argument.
  aws iam create-open-id-connect-provider \
    --url "https://${ISSUER}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  echo "[+] Created"
fi

# ---------------------------------------------------------------------------
# 2. Trust policy — the security-critical part
#
# StringEquals on `sub` pins assumption to exactly one repo and one branch.
# A wildcard here (or omitting the condition) would let ANY GitHub repo on
# the internet assume this role. `aud` must also be checked.
# ---------------------------------------------------------------------------
TRUST=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitHubActionsOIDC",
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${ISSUER}:aud": "sts.amazonaws.com",
          "${ISSUER}:sub": "${SUBJECT}"
        }
      }
    }
  ]
}
JSON
)

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "[=] Role exists — updating trust policy"
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${TRUST}"
else
  echo "[+] Creating role ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --description "Keyless deploys of ${GITHUB_ORG}/${GITHUB_REPO} to S3 + CloudFront" \
    --max-session-duration 3600 \
    --assume-role-policy-document "${TRUST}" >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Least-privilege permissions
# ---------------------------------------------------------------------------
PERMS=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListSiteBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET}"
    },
    {
      "Sid": "WriteSiteObjects",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Sid": "InvalidateDistribution",
      "Effect": "Allow",
      "Action": ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"],
      "Resource": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DISTRIBUTION_ID}"
    }
  ]
}
JSON
)

echo "[+] Applying least-privilege policy '${POLICY_NAME}'"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${PERMS}"

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo
echo "Done. Role ARN:"
echo "  ${ROLE_ARN}"
echo
echo "Set the GitHub secrets:"
echo "  gh secret set AWS_DEPLOY_ROLE_ARN --body '${ROLE_ARN}'"
echo "  gh secret set CLOUDFRONT_DISTRIBUTION_ID --body '${DISTRIBUTION_ID}'"
