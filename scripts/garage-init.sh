#!/bin/bash
# First-time Garage setup (idempotent): single-node layout, the media bucket, the access key from .env.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
g() { docker exec bc-garage /garage "$@"; }
node=$(g node id -q | cut -d@ -f1)
if ! g layout show 2>/dev/null | grep -q "$(echo "$node" | cut -c1-16)"; then
  g layout assign -z dc1 -c "${GARAGE_CAPACITY:-500G}" "$node"
  g layout apply --version 1
fi
g bucket info "$S3_BUCKET" >/dev/null 2>&1 || g bucket create "$S3_BUCKET"
g key info "$S3_ACCESS_KEY" >/dev/null 2>&1 || g key import --yes -n boostcontent "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
g bucket allow --read --write --owner "$S3_BUCKET" --key "$S3_ACCESS_KEY"
# CORS so a browser (Flutter web) can PUT/GET with the pre-signed URLs. The signature is the access
# control; CORS only lets the browser make the call.
docker run --rm --network host -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  -e AWS_DEFAULT_REGION=garage amazon/aws-cli:2.27.0 s3api put-bucket-cors --endpoint-url http://127.0.0.1:3900 \
  --bucket "$S3_BUCKET" --cors-configuration \
  '{"CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3600}]}'
g bucket info "$S3_BUCKET" | head -20
