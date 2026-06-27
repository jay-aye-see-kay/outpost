# Tech Stack Plan — Personal LLM Wiki

A personal, LLM-maintained wiki (per [karpathy's LLM Wiki idea](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)).
The wiki is the agent's persistent memory: a git repo of markdown that the agent
reads, writes, and keeps cross-referenced. This document covers **how the system
runs and syncs** — not the wiki's internal structure (see the wiki-structure plan).

## Goals & constraints

- **Phone-only access for now.** Drive the agent entirely from an iPhone.
- **Single writer.** One place edits the wiki (the server); GitHub is sync + backup.
- **Cheap, low-utilization.** ~10–30 min/day of real use; pay close to nothing when idle.
- **Low maintenance.** No long-lived server to patch and babysit.
- **Markdown + git.** The wiki is plain markdown; git is the only sync substrate.
- **Personal scale, occasional bugs acceptable.** Not production; favor simplicity.

## Architecture

```
iPhone (browser — opencode's built-in web UI; paste text / URLs, chat)
   │  HTTPS (Fly TLS) + HTTP Basic Auth; inbound connection WAKES the box
   ▼
Fly.io Machine   [scale-to-zero: auto_start = on, auto_stop = off, min = 0]
   • Image (Nix): opencode + git + gitwatch + curl + html→md
   • opencode (web server + agent) ──> opencode zen (managed model gateway)
   • gitwatch:      commit + push on every change (watches ~/llm-wiki)
   • idle-watcher:  ~N min no activity → halt the machine (clean stop)
   • Fly Volume mounted as HOME (~/): opencode DB + the wiki repo, both persist
   │  deploy key (SSH, write) — pull on wake / pushed continuously by gitwatch
   ▼
GitHub (single private repo — source of truth / backup)
```

The Fly Volume is mounted at the home directory (`HOME=/root`, volume at `/root`).
The wiki repo lives at `~/llm-wiki`; opencode runs with that as its working dir.
opencode's own state (`~/.local/share/opencode/opencode.db`, holding the zen
auth token and all sessions) sits on the same volume, so both the wiki and the
login survive scale-to-zero.

## Components & responsibilities

| Concern | Owner | Notes |
|---|---|---|
| Chat / phone UI | **opencode web UI** | built-in browser UI; no native app to install |
| The agent | **opencode** | runs with `~/llm-wiki` as its working dir |
| Model | **opencode zen** | managed gateway; token entered once in the web UI |
| Compute | **Fly.io** machine | scale-to-zero; wakes on inbound connection |
| Keep GitHub current | **gitwatch** | commit **and** push on change (one job) |
| Stop when idle | **idle-watcher** | ~N-min timer → clean `halt`; detection TBD |
| Wake the box | **Fly proxy** | `auto_start = on`, inbound connection starts it |
| Persistent state | **Fly Volume** | mounted as HOME: wiki repo + opencode DB |
| Sync / backup | **GitHub** | single private repo, source of truth |
| Image build | **Nix** (`dockerTools`) | push to registry → `fly deploy --image` |

## Key design decisions

1. **Memory lives in git, so compute is disposable.** The machine clones/holds the
   repo on a volume; GitHub is the source of truth. Losing the box loses at most an
   unpushed in-flight edit.

2. **Scale-to-zero, self-managed stop.** Fly has no precise "idle N minutes" knob,
   so we set `auto_stop = off` and let an **in-container idle-watcher halt the
   machine** after ~N min of no activity. The Fly proxy still **wakes** it on the
   next inbound connection. This gives a controlled grace window and avoids
   mid-session stops.

3. **gitwatch owns all git sync.** Commit *and* push, on change. Its debounce is
   seconds; the idle window is minutes — so everything is always pushed well before
   the box halts. The idle-watcher never touches git. Clean separation.

4. **Direct connection, not relay.** The phone's browser connects *into* Fly
   (Basic Auth + TLS) so the inbound connection can wake a stopped machine. A
   relay (daemon dialing out) can't wake a stopped box — so it's out.

5. **Least-privilege GitHub access.** A **deploy key** (SSH, write enabled) bound to
   the single wiki repo. Private key as a Fly secret, never baked into the image.
   GitHub host key pinned (no blind `StrictHostKeyChecking=no`).

6. **Nix-built image.** `opencode` (nixpkgs) + `git`, `gitwatch`, `curl`, and an
   HTML→markdown step, assembled via `dockerTools.buildLayeredImage`. Secrets stay
   out of the image.

7. **Ingest from phone.** Paste text and paste URLs; the agent fetches readable
   pages via `curl` + HTML→markdown. Scraper-blocked sites → paste the text.

8. **Volume is HOME; model login lives on it.** opencode stores the zen auth token
   in `~/.local/share/opencode/opencode.db`. Mounting the volume as HOME means the
   token is entered **once** in the web UI and then persists across scale-to-zero
   — no model API key needs to be a Fly secret.

## Auth & secrets

- **GitHub:** deploy key (ed25519, no passphrase, write access) on the wiki repo
  only. Private key via `fly secrets` (`GIT_DEPLOY_KEY`). Host key pinned in
  `known_hosts`. SSH remote.
- **opencode web server:** `OPENCODE_SERVER_PASSWORD` via `fly secrets` — enables
  HTTP Basic Auth on every request; the server is exposed over Fly's TLS.
  (Username defaults to `opencode`; override with `OPENCODE_SERVER_USERNAME`.)
- **Model (opencode zen):** *not* a Fly secret. The zen API key is entered once in
  the web UI and stored in the opencode DB on the volume.
- Secrets are injected at runtime as env; the Nix image stays secret-free.

Currently deployed secrets: `GIT_DEPLOY_KEY`, `OPENCODE_SERVER_PASSWORD`.

## Open questions (resolve while building)

- **opencode web UI hosting.** Confirm the self-hosted server (`opencode web` /
  `opencode serve`) actually serves the browser UI we hit from the phone — vs.
  opencode expecting a hosted web client pointed at the server URL. `opencode web`
  also auto-opens a local browser (harmless no-op on a headless box); we just need
  the server reachable over Fly TLS. Bind explicitly with `--hostname 0.0.0.0
  --port 8080` (it defaults to `127.0.0.1` + a random port, which the Fly proxy
  can't reach).
- **First-boot bootstrap.** Empty volume on first wake: clone the wiki into
  `~/llm-wiki`, and enter the opencode-zen token once in the web UI. Both then
  persist on the volume.
- **Idle detection mechanism.** Prefer an opencode-exposed session/activity signal
  over sniffing network connections; connection-watching is the fallback.
  Requirement is fixed (clean halt after ~N min idle); mechanism is open.
- **Wake-on-reconnect spike.** Verify the browser reconnecting reliably wakes a
  stopped/suspended machine through Fly's proxy. Fallback: cold `stop`, or
  `min_machines_running = 1` if needed.
- **Machine size & region.** Start `shared-cpu-1x` 512 MB–1 GB (work is remote API
  calls); region near the phone. Confirm once opencode's footprint is known.
- **Stop vs suspend.** Default toward a clean self-`halt`; revisit `suspend` if
  cold-start latency annoys.
- **Image rebuild flow.** Nix build (local/CI) → push to `registry.fly.io` →
  `fly deploy`. Pin the opencode version so updates don't surprise the box.
- **Observability / cost guard.** `fly logs`; a check that the box actually returns
  to zero and isn't quietly billing.

## Explicitly out of scope (for now)

- **Local devices / macbook gitwatch.** Phone-only; no launchd services yet.
- **Multi-writer conflicts.** Single writer (the box) = no real conflict risk.
  Adding a laptop later reintroduces this — revisit then.
- **Obsidian / GUI viewers.** The wiki is the agent's memory; markdown is enough.
  Browse files directly if needed.
