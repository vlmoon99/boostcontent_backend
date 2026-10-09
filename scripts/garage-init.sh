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
g bucket info "$S3_BUCKET" | head -20
