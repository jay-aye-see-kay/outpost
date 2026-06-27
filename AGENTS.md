# AGENTS.md

Personal LLM wiki on Fly.io. See `tech-stack.md` for the full plan

## Deploy & build

- `flake.nix` defines the image; `build-image.sh` builds it; `deploy.sh` ships it.
- **Get the user to run builds/deploys (outside the ai's agent sandbox)** — they need the real Docker daemon and your Fly credentials, which the sandbox blocks. The agent writes the flake/scripts; user runs them.

```bash
direnv allow                    # puts flyctl on PATH
flyctl auth login               # one-time
./build-image.sh                # -> outpost-image.tar.gz (only if flake changed)
./deploy.sh                     # push to registry.fly.io + fly deploy
flyctl logs --app outpost-wiki  # expect "=== outpost container up ==="
```

## Runtime model

- **opencode** runs as a headless web server (`opencode web`) with `~/llm-wiki` as
  its working dir; the phone hits the built-in web UI over Fly's TLS (HTTP Basic
  Auth via `OPENCODE_SERVER_PASSWORD`).
- **Model backend is opencode zen** — token entered once in the web UI, persisted
  in the opencode DB on the volume (no model key as a Fly secret).
- The **Fly Volume is mounted as HOME** (`HOME=/root`, volume at `/root`). The wiki
  git repo is `~/llm-wiki`; opencode state (`~/.local/share/opencode`) is on the
  same volume, so both survive scale-to-zero.
- **Secrets** (already deployed): `GIT_DEPLOY_KEY`, `OPENCODE_SERVER_PASSWORD`.

## Nix build details (why it's awkward)

- Image built with `dockerTools.buildLayeredImage`
- **Fly Machines are x86_64 only** — no ARM. So the image must target x86_64-linux
  even though the Mac is aarch64-darwin.
- No local Linux Nix builder, so `build-image.sh` runs an **emulated amd64
  `nixos/nix` container**. Cheap: all packages come prebuilt from cache.nixos.org;
  only the tar/gzip assembly runs emulated.
- Two emulation requirements baked into the script:
  - `filter-syscalls = false` (seccomp BPF can't load under emulation)
  - a named Docker volume holds `/nix` so deps aren't re-downloaded each run.

## Fly config

- One machine only: `deploy.sh` uses `--ha=false` (Fly defaults to 2 for HA).
- `auto_start = true`, `auto_stop = off`, `min_machines_running = 0` — proxy wakes
  it on inbound connection; in-container idle-watcher does the clean halt (later).
- `internal_port = 8080` is the port opencode's web server is bound to
  (`opencode web --hostname 0.0.0.0 --port 8080`).

## Cost / free tier

- Legacy free allowance: 3× shared-cpu-1x **256mb** VMs + 3GB volume.
- We run **512mb** (Node-based opencode; 256mb risks OOM) → just over free tier.
- With scale-to-zero ~23h/day, real cost ≈ **a few cents/month** (billed per-second
  while awake). Volume stays within the free 3GB.
