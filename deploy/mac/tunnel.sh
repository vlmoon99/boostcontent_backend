#!/bin/bash
# Publish this Mac's backend on a free Cloudflare quick tunnel (no account, no token) and point the
# backend at that address. The address is NEW on every start: the app must be built for it
# (Flutter: --dart-define=API_URL=<address>), and picture links signed for the old one stop working.
# For a fixed name use a named tunnel of your own Cloudflare account instead; never the boostcontent.io
# tunnel token, which belongs to the Sparks.
#   deploy/mac/tunnel.sh start | stop | url
set -uo pipefail
cd "$(dirname "$0")/../.."
LOGS=${LOGS:-$HOME/.cache/inf-mac/logs}; mkdir -p "$LOGS"
url() { grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOGS/tunnel.log" 2>/dev/null | tail -1; }
case "${1:-url}" in
  start)
    [ -f "$LOGS/tunnel.pid" ] && kill "$(cat "$LOGS/tunnel.pid")" 2>/dev/null
    : > "$LOGS/tunnel.log"
    nohup cloudflared tunnel --no-autoupdate --url http://localhost:3100 >> "$LOGS/tunnel.log" 2>&1 &
    echo $! > "$LOGS/tunnel.pid"
    for i in $(seq 60); do [ -n "$(url)" ] && break; sleep 1; done
    [ -n "$(url)" ] || { echo "no tunnel address: $LOGS/tunnel.log"; exit 1; }
    deploy/mac/up.sh "$(url)" | tail -2
    echo "public: $(url)" ;;
  stop) [ -f "$LOGS/tunnel.pid" ] && kill "$(cat "$LOGS/tunnel.pid")" 2>/dev/null; rm -f "$LOGS/tunnel.pid"; echo stopped ;;
  url) url ;;
esac
