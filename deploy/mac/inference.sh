#!/bin/bash
# Choose who answers the model calls of the backend running on this Mac.
#   deploy/mac/inference.sh sparks   # the Sparks' gateway over the tailnet (fast: big LLM, Qwen-Image-Edit)
#   deploy/mac/inference.sh mac      # inference_system/hosts/mac on this machine (works with the Sparks off)
#   deploy/mac/inference.sh status
# The backend, the database and the pictures stay on the Mac either way. With `sparks` the Mac's storage
# is published on its tailnet address, because the Sparks fetch the photo and put the picture themselves.
# Settings in .env: SPARK_GATEWAYS (first = the one Postgres calls), SPARK_INFERENCE_KEY (the project key
# `boostcontent` of the Sparks' gateway), MAC_INFERENCE_KEY (this Mac's own key).
set -euo pipefail
cd "$(dirname "$0")/../.."
[ -f .env ] || { echo "run deploy/mac/up.sh first"; exit 1; }
get() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '"'; }
put() { if grep -qE "^$1=" .env; then sed -i '' -e "s#^$1=.*#$1=$2#" .env; else echo "$1=$2" >> .env; fi; }
case "${1:-status}" in
  sparks)
    gateways=$(get SPARK_GATEWAYS); key=$(get SPARK_INFERENCE_KEY)
    [ -n "$gateways" ] && [ -n "$key" ] || { echo "set SPARK_GATEWAYS and SPARK_INFERENCE_KEY in .env"; exit 1; }
    ip=$(tailscale ip -4 2>/dev/null | head -1); [ -n "$ip" ] || { echo "this Mac is not on the tailnet"; exit 1; }
    first=${gateways%% *}
    curl -sf -m 5 "$first/health/liveliness" >/dev/null || { echo "$first does not answer: nothing changed"; exit 1; }
    put INFERENCE_URL "$first"; put INFERENCE_KEY "$key"; put INFERENCE_UPSTREAMS "\"$gateways\""
    put MAC_TAILNET_IP "$ip"; put S3_INTERNAL_ENDPOINT "http://$ip:3900"
    put MAC_LLM_CONCURRENCY 4; put MAC_IMAGE_CONCURRENCY 4; put MAC_IMAGES_PER_POST 3 ;;
  mac)
    key=$(get MAC_INFERENCE_KEY); [ -n "$key" ] || { echo "MAC_INFERENCE_KEY is not in .env"; exit 1; }
    put INFERENCE_URL http://host.docker.internal:8000; put INFERENCE_KEY "$key"
    put INFERENCE_UPSTREAMS http://host.docker.internal:8000
    sed -i '' -e '/^MAC_TAILNET_IP=/d' .env; put S3_INTERNAL_ENDPOINT http://127.0.0.1:3900
    put MAC_LLM_CONCURRENCY 2; put MAC_IMAGE_CONCURRENCY 2; put MAC_IMAGES_PER_POST 1 ;;
  status)
    echo "inference: $(get INFERENCE_URL)   storage for inference: $(get S3_INTERNAL_ENDPOINT)"; exit 0 ;;
  *) echo "usage: $0 sparks|mac|status"; exit 1 ;;
esac
deploy/mac/up.sh "$(get PUBLIC_URL)" | tail -2
echo "inference: $(get INFERENCE_URL)"
