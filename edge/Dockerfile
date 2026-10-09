# Caddy with the admin console baked in: `docker compose up --build` is the whole deploy.
FROM node:22-slim AS admin
WORKDIR /admin
COPY admin/package.json admin/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY admin/ ./
RUN npm run build

FROM caddy:2.10.0-alpine
COPY edge/Caddyfile /etc/caddy/Caddyfile
COPY --from=admin /admin/dist /srv/admin
