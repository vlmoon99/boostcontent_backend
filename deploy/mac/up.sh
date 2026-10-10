#!/bin/bash
# The whole backend on one Mac (Docker Desktop). The inference gateway runs natively on the same Mac
# (inference_system/hosts/mac): Docker on macOS has no GPU, so models cannot live in containers.
#
#   deploy/mac/up.sh                       # http://localhost:3100, this Mac only
#   deploy/mac/up.sh http://192.168.1.20:3100      # a phone on the same Wi-Fi
#   deploy/mac/up.sh https://<name>.trycloudflare.com   # through a Cloudflare tunnel (deploy/mac/tunnel.sh)
#   deploy/mac/up.sh down                  # stop (data stays in the docker volumes)
#
# The public URL is baked into every pre-signed picture link, so changing it means running this again.
# The first run writes .env with random secrets; later runs only change PUBLIC_URL / S3_PUBLIC_ENDPOINT.
set -euo pipefail
cd "$(dirname "$0")/../.."
dc() {
  local extra=()
  grep -qE '^MAC_TAILNET_IP=.+' .env 2>/dev/null && extra=(-f deploy/mac/compose.mac.tailnet.yaml)
  docker compose -f compose.yaml -f deploy/mac/compose.mac.yaml "${extra[@]}" --profile master "$@"
}
SERVICES="db migrate configure auth rest rest-admin garage caddy backup"

if [ "${1:-}" = down ]; then dc stop; exit 0; fi
PUBLIC=${1:-http://localhost:3100}
r() { openssl rand -hex "$1"; }

if [ ! -f .env ]; then
  cat > .env <<EOF
CLOUDFLARE_TUNNEL_TOKEN=
TAILNET_IP=127.0.0.1
PUBLIC_URL=$PUBLIC
DB_PASSWORD=$(r 24)
AUTHENTICATOR_PASSWORD=$(r 24)
AUTH_DB_PASSWORD=$(r 24)
ADMIN_AUTHENTICATOR_PASSWORD=$(r 24)
JWT_SECRET=$(r 32)
ADMIN_JWT_SECRET=$(r 32)
INFERENCE_URL=http://host.docker.internal:8000
INFERENCE_KEY=$(r 24)
S3_PUBLIC_ENDPOINT=$PUBLIC
S3_INTERNAL_ENDPOINT=http://127.0.0.1:3900
S3_BUCKET=bc-media
S3_ACCESS_KEY=GK$(r 12)
S3_SECRET_KEY=$(r 32)
GARAGE_RPC_SECRET=$(r 32)
GARAGE_ADMIN_TOKEN=$(r 32)
REPL_PASSWORD=
NODES=
GARAGE_CAPACITY=50G
EOF
  chmod 600 .env
  echo "wrote .env (random secrets)"
fi
sed -i '' -e "s#^PUBLIC_URL=.*#PUBLIC_URL=$PUBLIC#" -e "s#^S3_PUBLIC_ENDPOINT=.*#S3_PUBLIC_ENDPOINT=$PUBLIC#" .env

set -a; . ./.env; set +a          # MAC_* tuning below; deploy/mac/inference.sh writes it
dc up -d --build $SERVICES
scripts/garage-init.sh >/dev/null && echo "storage ready"

# This Mac's own tuning, in this Mac's database only (the Sparks keep their defaults): one GPU renders one
# picture at a time (~50 s each), so fewer jobs in flight and one picture per option instead of three.
docker exec -i bc-db psql -U postgres -d boostcontent -v ON_ERROR_STOP=1 -q <<SQL
insert into private.settings(key, value) values
  ('llm_concurrency', '${MAC_LLM_CONCURRENCY:-2}'), ('image_concurrency', '${MAC_IMAGE_CONCURRENCY:-2}')
on conflict (key) do update set value = excluded.value, updated_at = now();
update private.plans set images_per_post = ${MAC_IMAGES_PER_POST:-1};
SQL
echo "backend: $PUBLIC   (owner console: http://127.0.0.1:3200)"
