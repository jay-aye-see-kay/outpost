#!/usr/bin/env bash
# Build the (x86_64-linux) Fly image with Nix, inside a Docker/OrbStack container.
#
# Why a container: this Mac is aarch64-darwin with no Linux Nix builder, and Fly
# Machines are x86_64 only. So we run an emulated amd64 `nixos/nix` container to
# build. All packages come prebuilt from cache.nixos.org; only the lightweight
# image assembly (tar/gzip) runs emulated.
#
# Genuine emulation requirements (not optional):
#   * filter-syscalls=false  -> seccomp BPF can't load under emulation.
#   * a named volume holds /nix so deps aren't re-downloaded every run.
#
# Output: ./outpost-image.tar.gz  (a `docker load`-able image)
#
# Run this OUTSIDE the agent sandbox (it needs the real Docker daemon).
set -euo pipefail
cd "$(dirname "$0")"

docker volume create outpost-nix-store >/dev/null

docker run --rm --platform linux/amd64 \
  -v outpost-nix-store:/nix \
  -v "$PWD":/work -w /work \
  -e NIX_CONFIG=$'extra-experimental-features = nix-command flakes\nfilter-syscalls = false' \
  nixos/nix \
  bash -c 'out=$(nix build .#image --no-link --print-out-paths) && cp "$out" /work/outpost-image.tar.gz && chmod u+w /work/outpost-image.tar.gz && echo "BUILT: $out"'

echo "Wrote $PWD/outpost-image.tar.gz"
