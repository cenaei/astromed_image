# AstroMed — Offline Docker Deployment (Arvan CDN + Caddy)

Build on Windows 11 (online), ship `.tar` files to the Ubuntu 24.04 server,
run the stack, and expose the site on a domain via **Arvan Cloud CDN** with
Caddy acting as a plain-HTTP origin.

```
+---------------------------+   scp / usb   +---------------------------+
| Windows 11 (online)      | -------------> | Ubuntu 24.04              |
|   docker build / save     |               |   docker load + compose   |
|   -> astromed.tar         |               |   migrate + seed          |
|   -> postgres16.tar       |               |   Caddy (HTTP:80 origin)  |
+---------------------------+               +---------------------------+
                                                    ^
                                                    | origin = http://SERVER_IP:80
                                          +---------------------------+
                                          | Arvan Cloud CDN           |
                                          |   Free SSL / TLS at edge  |
                                          |   https://your-domain.com |
                                          +---------------------------+
```

> **TLS layout:** Arvan terminates HTTPS at its edge (Free SSL) and proxies to
> your server over **HTTP:80**. Caddy therefore runs on **plain HTTP** and never
> requests Let's Encrypt certs (which would fail through the proxy anyway).

---

## 0. Prerequisites on the server

- Ubuntu 24.04
- Docker Engine + Docker Compose v2 installed (do this while online):
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo systemctl enable --now docker
  sudo usermod -aG docker $USER      # then log out/in, or use sudo below
  ```
- A public IP reachable by Arvan.

---

## 1. Build on Windows 11 (PowerShell, online)

```powershell
cd D:\ssh\astro-med

docker build -t astromed:latest .          # network required
docker pull postgres:16                    # network required

docker save -o astromed.tar astromed:latest
docker save -o postgres16.tar postgres:16
```

Result: `astromed.tar` (~292 MB) and `postgres16.tar` (~158 MB).

---

## 2. Transfer to the server

```powershell
scp astromed.tar postgres16.tar docker-compose.yml \
    user@SERVER_IP:/srv/astromed/

# Caddy site config + one-shot provisioning script
scp deploy/caddy-setup/Caddyfile user@SERVER_IP:/srv/astromed/Caddyfile
scp deploy/server-deploy.sh      user@SERVER_IP:/srv/astromed/deploy/
scp deploy/env.production.example user@SERVER_IP:/srv/astromed/
```

---

## 3. Configure `.env` on the server

```bash
sudo mkdir -p /srv/astromed/uploads
cd /srv/astromed
cp env.production.example .env
nano .env
```

Fill in real values (secrets via `openssl rand -hex 32`):
```dotenv
POSTGRES_USER=postgres
POSTGRES_PASSWORD=REPLACE_STRONG_DB_PASSWORD
POSTGRES_DB=astromed

AUTH_SECRET=REPLACE             # openssl rand -hex 32
NUXT_OG_IMAGE_SECRET=REPLACE    # openssl rand -hex 32

SITE_URL=https://your-domain.com
AUTH_ORIGIN=https://your-domain.com

SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASS=your-app-password
NUXT_MAIL_MESSAGE_TO=info@astromed-co.com
```

> `SITE_URL` and `AUTH_ORIGIN` must be the **public** HTTPS domain (Arvan's),
> not the origin IP — the browser talks to `https://your-domain.com`.

---

## 4. Load images, start stack, seed (offline)

```bash
cd /srv/astromed

docker load -i astromed.tar
docker load -i postgres16.tar

docker compose up -d     # web auto-runs `prisma migrate deploy` before boot
docker compose exec web npx prisma db seed   # ONE-TIME
```

Check:
```bash
docker compose ps                 # both running / healthy
curl -I http://localhost:3000      # expect HTTP 200 (internal origin)
```

---

## 5. Run the one-shot provisioning (Caddy + firewall)

```bash
cd /srv/astromed
DOMAIN=your-domain.com bash deploy/server-deploy.sh
```

This: installs Caddy (needs internet), writes `/etc/caddy/Caddyfile` with your
domain (plain HTTP), opens **:80 (origin)** and **:22 (SSH)**, and leaves
**:443 closed** (Arvan handles TLS).

Verify origin directly (bypassing Arvan) on the server:
```bash
curl -H "Host: your-domain.com" -I http://localhost:80   # expect HTTP 200
```

---

## 6. Configure Arvan Cloud CDN (panel)

1. **Add your domain** to Arvan Cloud → **CDN** (nameservers already point to
   Arvan — this is what you've done).
2. **DNS:** keep the `A` record pointing at `SERVER_IP` with the proxy enabled
   (orange cloud). Arvan resolves `your-domain.com` to its edge.
3. **SSL/TLS:** set mode to **Free SSL** and enable **Force HTTPS** / 301
   redirect. The origin connection to your server stays **HTTP**.
4. **Origin:** set the origin server to `http://SERVER_IP` port **80**
   (matching Caddy). Do NOT use `https://` for the origin.
5. **Cache rules (critical for SSR):**
   - **Do NOT cache HTML/dynamic routes** (`/`, `/products/*`, `/admin`, API).
     Nuxt renders pages per-request — caching HTML shows stale content.
   - **Cache** `/uploads/*`, `/_nuxt/*`, `/favicon.ico` and other static assets.
6. **Security (recommended):** enable origin-access restriction so only Arvan
   edge IPs can reach `SERVER_IP:80` (prevents direct-origin bypass).
7. **Purge cache** after the first deploy.

---

## 7. Verify the site is visible

```bash
curl -I https://your-domain.com      # expect HTTP 200 + TLS from Arvan
```
Open `https://your-domain.com` in a browser. Watch logs:
```bash
cd /srv/astromed && docker compose logs -f web
```

If the site loads but looks broken (stale HTML): purge Arvan's cache — the
HTML was cached during setup.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `curl https://your-domain.com` fails/ERR_CONNECTION | DNS proxy off, nameservers not on Arvan, or :80 closed → `ufw allow 80/tcp` |
| Origin reachable via `SERVER_IP` but not via domain | Arvan proxy record not enabled for the `A`/`AAAA` entry |
| `curl -H "Host: ..." http://localhost:80` fails | Caddy not running → `sudo systemctl status caddy` |
| Stale HTML pages | Arvan cached HTML → add cache-exclusion rule + purge |
| 443 refused on origin | Expected — Arvan handles TLS; don't open 443 |
| Arvan origin probe timeout | Temporarily `ufw allow 443/tcp`, retest, then `ufw deny 443/tcp` |

---

## Upgrade flow

```bash
# Windows: rebuild + re-export
cd D:\ssh\astro-med
docker build -t astromed:latest .
docker save -o astromed.tar astromed:latest

# Server: load + restart (data, uploads, postgres volume all persist)
cd /srv/astromed
docker load -i astromed.tar
docker compose up -d
# Purge Arvan cache after deploying (HTML could be cached)
```

New DB migrations apply automatically on web container start.

---

## Backups

```bash
cd /srv/astromed
docker compose exec db pg_dump -U postgres astromed | gzip > backup-$(date +%F).sql.gz
# uploads live in /srv/astromed/uploads (plain files — copy them too)
```

---

## Gotchas

- **Caddy is HTTP-only here.** Do not give Caddy a bare hostname (e.g. without
  `http://`); it will attempt automatic HTTPS and fail behind the CDN.
- **Node 20 + pnpm:** Dockerfile pins **pnpm 10** (Node 20 compatible). The repo's
  `packageManager` field pins pnpm 11 (needs Node 22); managed-version switching
  is disabled in the image. No action needed on the server.
- **Prisma engine is Linux:** built inside the container; local Windows `.output`
  is ignored via `.dockerignore`.
- **Secrets baked in?** No. Everything sensitive comes from the server `.env`
  through `NUXT_*` compose env vars.
- **Seed is idempotent** (upserts); safe to re-run on existing data.