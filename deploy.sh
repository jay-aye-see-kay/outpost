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

APP="${FLY_APP:-outpost-wiki}"   # change if the name is taken
IMG="registry.fly.io/${APP}:latest"

# First time only: create the app (no deploy yet).
flyctl apps list | grep -q "^${APP}\b" || flyctl apps create "$APP"

# Let Docker talk to Fly's registry.
flyctl auth docker

# Load the Nix image tarball, retag for Fly's registry, push.
docker load -i outpost-image.tar.gz          # loads outpost:latest
docker tag outpost:latest "$IMG"
docker push "$IMG"

# Deploy the pushed image to a Machine.
flyctl deploy --app "$APP" --image "$IMG"

echo "Deployed $IMG to app $APP"
echo "Check it:  flyctl logs --app $APP"
