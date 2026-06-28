# One-shot boot setup: deploy key, git identity, clone the wiki if absent.
# Runs to completion before opencode/gitwatch/idle-watcher start (process-compose
# depends_on: process_completed_successfully). Idempotent across reboots.
#
# Note: no GIT_SSH_COMMAND override — ssh's defaults ($HOME/.ssh/id_ed25519 +
# $HOME/.ssh/known_hosts) already cover us now that HOME is set.

HOME_DIR="${HOME:-/root}"
WIKI="${WIKI:-/root/llm-wiki}"

echo "=== outpost bootstrap ==="

mkdir -p "$HOME_DIR"

# GitHub deploy key (from the GIT_DEPLOY_KEY secret, never baked into the image)
# plus a pinned host key (no blind StrictHostKeyChecking=no).
install -d -m 700 "$HOME_DIR/.ssh"
if [ -n "${GIT_DEPLOY_KEY:-}" ]; then
  printf '%s\n' "$GIT_DEPLOY_KEY" > "$HOME_DIR/.ssh/id_ed25519"
  chmod 600 "$HOME_DIR/.ssh/id_ed25519"
fi
cat > "$HOME_DIR/.ssh/known_hosts" <<'KNOWN'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
KNOWN
chmod 644 "$HOME_DIR/.ssh/known_hosts"

# Identity gitwatch commits under, and trust the repo dir.
git config --global user.name "outpost"
git config --global user.email "outpost@localhost"
git config --global --add safe.directory "$WIKI"

# Clone on first boot (empty volume); later boots already have the repo.
if [ ! -d "$WIKI/.git" ]; then
  if [ -n "${WIKI_REPO:-}" ]; then
    echo "=== cloning $WIKI_REPO into $WIKI ==="
    git clone "$WIKI_REPO" "$WIKI" || { echo "clone FAILED"; mkdir -p "$WIKI"; }
  else
    echo "=== WIKI_REPO unset; starting with an empty $WIKI ==="
    mkdir -p "$WIKI"
  fi
fi

# Bootstrap done; process-compose now starts opencode + gitwatch. This is the
# marker to grep for after a deploy (see AGENTS.md).
echo "=== outpost container up ==="
