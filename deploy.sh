#!/usr/bin/env bash
# Rebuild + redeploy AstroMed on the server, with zero-downtime-ish restart.
set -euo pipefail

cd /srv/astromed
git pull --ff-only
pnpm install --frozen-lockfile
pnpm exec prisma migrate deploy
pnpm build
systemctl restart astromed
echo "Deploy complete: $(date)"