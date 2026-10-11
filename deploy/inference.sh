#!/bin/bash
# Choose who answers this node's model calls. Run it on EVERY node, so a takeover keeps the choice.
#   deploy/inference.sh cloud    # NEAR AI (text, embeddings) and Comfy Cloud (pictures): inference_system/hosts/cloud, :8011
#   deploy/inference.sh own      # this cluster's own models: the node's gateway, :8000
#   deploy/inference.sh status
# Only the address and key the backend calls change (.env: INFERENCE_URL, INFERENCE_KEY, then private.settings
# on the master). The inference system itself is not touched: both gateways keep running either way, and
# api.vramhouse.com (INFERENCE_UPSTREAMS) keeps reaching the cluster's own models.
# Settings in .env: CLOUD_INFERENCE_KEY (the API_KEY of hosts/cloud/.env) and, saved by the first switch,
# OWN_INFERENCE_KEY (the project key of the own gateway). Optional: CLOUD_INFERENCE_URL, OWN_INFERENCE_URL.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env here"; exit 1; }
get() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | tr -d '"'; }
put() { if grep -qE "^$1=" .env; then sed -i -e "s#^$1=.*#$1=$2#" .env; else echo "$1=$2" >> .env; fi; }
ip=$(get TAILNET_IP)
cloud_url=$(get CLOUD_INFERENCE_URL); cloud_url=${cloud_url:-http://$ip:8011}
own_url=$(get OWN_INFERENCE_URL); own_url=${own_url:-http://$ip:8000}
now=$(get INFERENCE_URL)
case "${1:-status}" in
  cloud)
    key=$(get CLOUD_INFERENCE_KEY); [ -n "$key" ] || { echo "set CLOUD_INFERENCE_KEY in .env (API_KEY of inference_system/hosts/cloud/.env)"; exit 1; }
    curl -sf -m 15 "$cloud_url/health" | grep -q '"ok":true' || { echo "$cloud_url does not answer: nothing changed"; exit 1; }
    [ -n "$(get OWN_INFERENCE_KEY)" ] || [ "$now" = "$cloud_url" ] || put OWN_INFERENCE_KEY "$(get INFERENCE_KEY)"
    put INFERENCE_URL "$cloud_url"; put INFERENCE_KEY "$key" ;;
  own)
    key=$(get OWN_INFERENCE_KEY)
    [ -n "$key" ] || { [ "$now" != "$cloud_url" ] && key=$(get INFERENCE_KEY); }
    [ -n "$key" ] || { echo "OWN_INFERENCE_KEY is not in .env"; exit 1; }
    curl -sf -m 5 "$own_url/health/liveliness" >/dev/null || { echo "$own_url does not answer: nothing changed"; exit 1; }
    put INFERENCE_URL "$own_url"; put INFERENCE_KEY "$key" ;;
  status)
    [ "$now" = "$cloud_url" ] && echo "model calls: cloud ($now)" || echo "model calls: own models ($now)"; exit 0 ;;
  *) echo "usage: $0 cloud|own|status"; exit 1 ;;
esac
# The database holds the address the engine calls. Only a master can be written; a follower gets it by replication,
# and its own .env is what counts if it ever takes over (configure runs on every start).
if [ "$(docker exec bc-db psql -X -U postgres -d boostcontent -tAc 'select pg_is_in_recovery()' 2>/dev/null)" = f ]; then
  docker compose --profile master run --rm --no-deps configure >/dev/null
  docker exec bc-db psql -X -U postgres -d boostcontent -qc "select private.refresh_llm_proof()" >/dev/null 2>&1 || true
  echo "model calls: $(get INFERENCE_URL) (written to the database)"
else
  echo "model calls: $(get INFERENCE_URL) (this node is not the master: .env only)"
fi
