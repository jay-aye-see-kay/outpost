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
iPhone (Paseo app — paste text / URLs, voice, chat)
   │  WebSocket (TLS, password-auth); inbound connection WAKES the box
   ▼
Fly.io Machine   [scale-to-zero: auto_start = on, auto_stop = off, min = 0]
   • Image (Nix): paseo + pi-coding-agent + git + gitwatch + curl + html→md
   • Paseo daemon ──> Pi (agent) ──> Claude Sonnet (Anthropic)
   • gitwatch:      commit + push on every change
   • idle-watcher:  ~N min no activity → halt the machine (clean stop)
   • wiki repo on a Fly Volume (persists across stop/start)
   │  deploy key (SSH, write) — pull on wake / pushed continuously by gitwatch
   ▼
GitHub (single private repo — source of truth / backup)
```

## Components & responsibilities

| Concern | Owner | Notes |
|---|---|---|
| Chat / phone UI | **Paseo** app + daemon | iOS client; voice + text; Pi as backend |
| The agent | **Pi** | runs against the wiki repo as its working dir |
| Model | **Anthropic Claude Sonnet** | API key as a Fly secret |
| Compute | **Fly.io** machine | scale-to-zero; wakes on inbound connection |
| Keep GitHub current | **gitwatch** | commit **and** push on change (one job) |
| Stop when idle | **idle-watcher** | ~N-min timer → clean `halt`; detection TBD |
| Wake the box | **Fly proxy** | `auto_start = on`, inbound connection starts it |
| Persistent state | **Fly Volume** | repo + Paseo daemon home |
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

4. **Direct connection, not relay.** The phone connects *into* Fly (password + TLS)
   so the inbound connection can wake a stopped machine. A relay (daemon dialing
   out) can't wake a stopped box — so it's out.

5. **Least-privilege GitHub access.** A **deploy key** (SSH, write enabled) bound to
   the single wiki repo. Private key as a Fly secret, never baked into the image.
   GitHub host key pinned (no blind `StrictHostKeyChecking=no`).

6. **Nix-built image.** `pi-coding-agent` (nixpkgs) + `paseo` (its flake) + `git`,
   `gitwatch`, `curl`, and an HTML→markdown step, assembled via
   `dockerTools.buildLayeredImage`. Secrets stay out of the image.

7. **Ingest from phone.** Paste text and paste URLs; the agent fetches readable
   pages via `curl` + HTML→markdown. Scraper-blocked sites → paste the text.

## Auth & secrets

- **GitHub:** deploy key (ed25519, no passphrase, write access) on the wiki repo
  only. Private key via `fly secrets`. Host key pinned in `known_hosts`. SSH remote.
- **Anthropic:** `ANTHROPIC_API_KEY` via `fly secrets`.
- **Paseo:** `PASEO_PASSWORD` via `fly secrets`; daemon exposed over Fly's TLS.
- Secrets are injected at runtime as env; the Nix image stays secret-free.

## Open questions (resolve while building)

- **Idle detection mechanism.** Prefer a Paseo-exposed session/activity signal over
  sniffing network connections; connection-watching is the fallback. Requirement is
  fixed (clean halt after ~N min idle); mechanism is open.
- **Paseo remote pairing + daemon state.** Confirm pairing/history survive
  stop/start — likely means putting the daemon home on the Fly Volume.
- **Wake-on-reconnect spike.** Verify the Paseo app reconnecting reliably wakes a
  stopped/suspended machine through Fly's proxy. Fallback: cold `stop`, or
  `min_machines_running = 1` if needed.
- **Machine size & region.** Start `shared-cpu-1x` 512 MB–1 GB (work is remote API
  calls); region near the phone. Confirm once the daemon's footprint is known.
- **Stop vs suspend.** Default toward a clean self-`halt`; revisit `suspend` if
  cold-start latency annoys.
- **Image rebuild flow.** Nix build (local/CI) → push to `registry.fly.io` →
  `fly deploy`. Pin Paseo + Pi versions so updates don't surprise the box.
- **Observability / cost guard.** `fly logs`; a check that the box actually returns
  to zero and isn't quietly billing.

## Explicitly out of scope (for now)

- **Local devices / macbook gitwatch.** Phone-only; no launchd services yet.
- **Multi-writer conflicts.** Single writer (the box) = no real conflict risk.
  Adding a laptop later reintroduces this — revisit then.
- **Obsidian / GUI viewers.** The wiki is the agent's memory; markdown is enough.
  Browse files directly if needed.
