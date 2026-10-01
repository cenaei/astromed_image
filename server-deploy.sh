#!/usr/bin/env bash
#
# AstroMed — one-shot offline server provisioning (Ubuntu 24.04)
#
# Run on the server AFTER transferring the tarballs + compose + .env:
#   bash /srv/astromed/deploy/server-deploy.sh
#
# Steps: load images, start stack, wait for migrate, seed DB,
#        install Caddy, apply Caddyfile, open firewall.
# Idempotent: safe to re-run.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/astromed}"
DOMAIN="${DOMAIN:-}"                      # required for Caddy
SEED="${SEED:-1}"                         # set SEED=0 to skip seeding
INSTALL_CADDY="${INSTALL_CADDY:-1}"       # set to 0 if Caddy already present

cd "$APP_DIR"

log()  { printf '\033[1;32m[deploy]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f docker-compose.yml ] || die "docker-compose.yml missing in $APP_DIR"
[ -f .env ] || die ".env missing — copy deploy/env.production.example to $APP_DIR/.env and fill it in"

# ---------------------------------------------------------------- load images
log "Loading images (no network required)"
[ -f astromed.tar ]  && docker load -i astromed.tar  || true
[ -f postgres16.tar ] && docker load -i postgres16.tar || true

# ---------------------------------------------------------------- start stack
log "Starting stack (web auto-runs prisma migrate deploy)"
docker compose up -d

log "Waiting for db + web to be healthy..."
docker compose wait db 2>/dev/null || true

# ---------------------------------------------------------------- seed
if [ "$SEED" = "1" ]; then
  log "Seeding database (idempotent — safe to re-run)"
  docker compose exec -T web npx prisma db seed
fi

# ---------------------------------------------------------------- smoke test
log "Internal smoke test"
curl -fsSI http://localhost:3000 >/dev/null && echo "  http://localhost:3000 -> OK"

# ---------------------------------------------------------------- caddy
if [ "$INSTALL_CADDY" = "1" ] && [ -n "$DOMAIN" ]; then
  log "Installing Caddy (needs internet — skip if offline / already installed)"
  if ! command -v caddy >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -y
    apt-get install -y caddy
  fi

  log "Configuring Caddy for $DOMAIN"
  sed "s/YOUR_DOMAIN/$DOMAIN/g" "$APP_DIR/Caddyfile" > /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy || true
fi

# ---------------------------------------------------------------- firewall
# Arvan CDN terminates TLS at the edge and reaches this server over HTTP:80.
# So only :80 (origin) and :22 (SSH) need to be open; 443 stays closed.
#
# If Arvan's origin probe needs a moment on 443 during the DNS cutover, run:
#   ufw allow 443/tcp && docker compose up -d
#   ... verify, then:
#   ufw deny 443/tcp
log "Opening 80 (origin) + 22 (SSH); leaving 443 closed (Arvan handles TLS)"
ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow OpenSSH >/dev/null 2>&1 || true

# ---------------------------------------------------------------- done
log "Done!"
echo "  Internal origin: http://SERVER_IP (port 80) <- Arvan Free SSL"
echo "  Public site:     https://$DOMAIN"
echo "  Logs:   docker compose -f $APP_DIR/docker-compose.yml logs -f web"
