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

# Ensure the persistent volume exists (idempotent). fly.toml mounts "outpost_data"
# at /data; deploy fails if no volume of that name exists in the primary region.
# Volumes are region-bound, so create it in the app's primary_region.
VOLUME="${FLY_VOLUME:-outpost_data}"
REGION="$(awk -F'"' '/primary_region/ {print $2}' fly.toml)"
if flyctl volumes list --app "$APP" 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$VOLUME"; then
  echo "Volume $VOLUME already exists — skipping create."
else
  echo "Creating volume $VOLUME in $REGION ..."
  flyctl volumes create "$VOLUME" --app "$APP" --region "$REGION" --size 1 --yes
fi

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
