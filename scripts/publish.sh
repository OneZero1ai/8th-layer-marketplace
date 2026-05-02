#!/usr/bin/env bash
# Publish marketplace.json to the public CloudFront URL at
# https://8thlayer.onezero1.ai/marketplace.json
#
# Source of truth is .claude-plugin/marketplace.json (used by Claude
# Code's git-clone install path). This script copies that file to the
# 8th-layer-app S3 bucket that backs the 8thlayer.onezero1.ai
# CloudFront distribution, then invalidates the /marketplace.json path
# so the change is live within ~30s.
#
# Usage: bash scripts/publish.sh
# Requires: AWS profile `8th-layer-app` configured with credentials.
#
# Why bash + AWS CLI rather than a CI workflow: the operator runs this
# manually after vetting the catalog change. Avoids a third-party
# (GitHub Actions) execution path on the deploy line. See decision
# 14's repo-audit + the avoid-github-dependencies rule.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${REPO_ROOT}/.claude-plugin/marketplace.json"

# These match the production CloudFront distribution backing
# 8thlayer.onezero1.ai (S3 origin: 8l-web-site-us-east-1-...).
AWS_PROFILE="${AWS_PROFILE_OVERRIDE:-8th-layer-app}"
S3_BUCKET="8l-web-site-us-east-1-124074140789"
S3_KEY="marketplace.json"
CLOUDFRONT_DIST_ID="EEUW0F2ICYKFQ"

if [[ ! -f "$SOURCE" ]]; then
    echo "ERROR: $SOURCE missing" >&2
    exit 1
fi

# Validate the JSON before publishing. A broken catalog locks every
# customer out of /plugin marketplace add until we re-publish.
if ! python3 -c "import json,sys; json.load(open('$SOURCE'))" 2>/dev/null; then
    echo "ERROR: $SOURCE is not valid JSON" >&2
    exit 1
fi

echo "[publish] uploading $SOURCE -> s3://$S3_BUCKET/$S3_KEY"
aws s3 cp "$SOURCE" "s3://$S3_BUCKET/$S3_KEY" \
    --profile "$AWS_PROFILE" \
    --content-type "application/json" \
    --cache-control "public, max-age=300"

echo "[publish] invalidating CloudFront /$S3_KEY"
INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --profile "$AWS_PROFILE" \
    --distribution-id "$CLOUDFRONT_DIST_ID" \
    --paths "/$S3_KEY" \
    --query 'Invalidation.Id' --output text)

echo "[publish] invalidation $INVALIDATION_ID submitted; live in ~30s"
echo "[publish] verify: curl https://8thlayer.onezero1.ai/marketplace.json | head"
