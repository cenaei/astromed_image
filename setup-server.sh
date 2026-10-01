#!/usr/bin/env bash
#
# AstroMed — one-shot Ubuntu 24 server setup
#
# Run as root on a FRESH Ubuntu 24 server:
#   bash setup-server.sh
#
# It provisions Node 20, pnpm, PostgreSQL 16, Caddy, ufw, the app user,
# clones the repo via a GitHub deploy key, writes .env, migrates, seeds,
# builds, and installs the systemd unit + Caddy site.
#
# Idempotent: safe to re-run.
set -euo pipefail

# ---------------------------------------------------------------- config
DOMAIN="${DOMAIN:-}"
REPO_SSH="${REPO_SSH:-git@github.com:cenaei/astro-med.git}"
APP_DIR="${APP_DIR:-/srv/astromed}"
UPLOAD_DIR="${UPLOAD_DIR:-$APP_DIR/uploads}"
DB_NAME=astromed
DB_USER=astromed
DB_PASS="${DB_PASS:-}"
APP_USER=deploy

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo -i)."

[ -n "$DOMAIN" ] || read -r -p "Your domain (no protocol, e.g. astromed.com): " DOMAIN
[ -n "$DOMAIN" ] || die "DOMAIN is required."
if [ -z "$DB_PASS" ]; then
  DB_PASS="$(openssl rand -base64 24 | tr '+/' 'Aa')"
  log "Generated database password (kept only in /srv/astromed/.env)"
fi

# ---------------------------------------------------------------- packages
log "Installing system packages + Node 20 + pnpm"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl ufw ca-certificates gnupg lsb-release software-properties-common

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
corepack enable
corepack prepare pnpm@11.18.0 --activate

# ---------------------------------------------------------------- app user
if ! id "$APP_USER" &>/dev/null; then
  adduser --gecos "" --disabled-password "$APP_USER"
  usermod -aG sudo "$APP_USER"
  log "Created user '$APP_USER'"
fi

# ---------------------------------------------------------------- firewall
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
log "Firewall enabled (22/80/443)"

# ---------------------------------------------------------------- postgres
log "Installing / starting PostgreSQL 16"
apt-get install -y postgresql
systemctl enable --now postgresql
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
  || sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
log "Database '$DB_NAME' ready (owner: $DB_USER)"

# ---------------------------------------------------------------- deploy key
sudo -i -u "$APP_USER" bash -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
  grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null || ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null'
PUBKEY="$(sudo cat /home/$APP_USER/.ssh/id_ed25519.pub)"

# ---------------------------------------------------------------- clone (needs deploy key on GitHub)
sudo mkdir -p "$APP_DIR" && sudo chown "$APP_USER":"$APP_USER" "$APP_DIR"
log "Trying to clone $REPO_SSH"
if ! sudo -u "$APP_USER" git clone "$REPO_SSH" "$APP_DIR" 2>/tmp/clone.err; then
  warn "Clone failed — the deploy key below is probably not added to GitHub yet."
  printf '\n  %s\n\n' "$PUBKEY"
  read -r -p "Add the key above to GitHub -> repo -> Settings -> Deploy keys (read-only), then press Enter to retry... "
  rm -rf "$APP_DIR/.git" 2>/dev/null || true
  sudo -u "$APP_USER" git clone "$REPO_SSH" "$APP_DIR" || die "Clone still failing. Abort."
fi
log "Repo cloned into $APP_DIR"

# ---------------------------------------------------------------- .env
log "Writing $APP_DIR/.env"
cat > "$APP_DIR/.env" <<EOF
DATABASE_URL="postgresql://$DB_USER:$DB_PASS@127.0.0.1:5432/$DB_NAME?schema=public"
AUTH_SECRET="$(openssl rand -hex 32)"
NUXT_OG_IMAGE_SECRET="$(openssl rand -hex 32)"
SITE_URL="https://$DOMAIN"
UPLOAD_DIR="$UPLOAD_DIR"
NODE_ENV=production
PORT=3000
EOF
chown "$APP_USER":"$APP_USER" "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

# ---------------------------------------------------------------- install / migrate / seed / build
log "Installing dependencies (pnpm)"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && pnpm install --frozen-lockfile"

log "Running prisma migrate deploy"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && pnpm exec prisma migrate deploy"

log "Seeding database (creates admin, content, and copies legacy images to uploads)"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && pnpm exec prisma db seed"

log "Building production bundle (nuxt build)"
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && pnpm build"

# ---------------------------------------------------------------- systemd
log "Installing systemd unit"
cp "$APP_DIR/deploy/astromed.service" /etc/systemd/system/astromed.service
systemctl daemon-reload
systemctl enable --now astromed
log "astromed.service started"

# ---------------------------------------------------------------- caddy
log "Installing Caddy"
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy
sed "s|<your-domain>|$DOMAIN|g" "$APP_DIR/deploy/Caddyfile" > /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy || true
log "Caddy configured for https://$DOMAIN"

# ---------------------------------------------------------------- done
log "Setup complete!"
log "  Site:      https://$DOMAIN"
log "  Admin:     https://$DOMAIN/admin  (admin@astromed-co.com / admin123 — CHANGE after first login)"
log "  Deploy:    bash $APP_DIR/deploy/deploy.sh"
log "  Backups:   (next step — set up the pg_dump cron)"
printf '\033[1;33m%s\033[0m\n' "IMPORTANT: if your DNS/CDN proxies traffic, keep it DNS-only until the TLS cert issues."