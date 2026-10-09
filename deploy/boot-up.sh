#!/bin/bash
# After a power cut: wait for the tailnet IP (Caddy :3200 and Garage :3900 publish on it), then
# `docker compose up -d` (idempotent: migrate + configure re-run harmlessly). Run by bc-stack.service.
set -uo pipefail
cd "$(dirname "$0")/.."
ip=$(grep -E '^TAILNET_IP=' .env | cut -d= -f2)
for i in $(seq 120); do ip -4 addr | grep -q " ${ip}/" && break; sleep 5; done
for i in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker compose up -d --no-build 2>&1 | tail -20
