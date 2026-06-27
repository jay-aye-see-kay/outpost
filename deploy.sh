#!/usr/bin/env bash
# Push the Nix-built image to Fly's registry and deploy it.
#
# Run this OUTSIDE the agent sandbox (needs Docker + your Fly credentials).
# Prereqs:
#   * ./build-image.sh has produced ./outpost-image.tar.gz
#   * flyctl is on PATH (it's in the devShell: `nix develop`)
#   * you're logged in:  flyctl auth login
set -euo pipefail
cd "$(dirname "$0")"

APP="${FLY_APP:-outpost-wiki}" # globally unique; override: FLY_APP=... ./deploy.sh
IMG="registry.fly.io/${APP}:latest"

# Ensure the app exists (idempotent). `apps list` shows only YOUR org's apps, so
# an exact first-column match means it's already created -> skip create, just deploy.
# A create failing with "Name has already been taken" here means another org owns
# that global name: pick a different $APP.
if flyctl apps list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$APP"; then
  echo "App $APP already exists — skipping create."
else
  echo "Creating app $APP ..."
  flyctl apps create "$APP"
fi

# Let Docker talk to Fly's registry.
flyctl auth docker

# Load the Nix image tarball, retag for Fly's registry, push.
docker load -i outpost-image.tar.gz # loads outpost:latest
docker tag outpost:latest "$IMG"
docker push "$IMG"

# Deploy the pushed image to a single Machine (--ha=false => one machine, not two).
flyctl deploy --app "$APP" --image "$IMG" --ha=false

# If a previous deploy already created a pair, collapse to one:
flyctl scale count 1 --app "$APP" --yes

echo "Deployed $IMG to app $APP"
echo "Check it:  flyctl logs --app $APP"
