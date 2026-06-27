# Halt the Fly Machine after IDLE_MINUTES with no opencode activity, so the box
# scales to zero. opencode has no built-in idle timeout, so we watch its event
# stream: any non-heartbeat event = activity. Before halting we also confirm no
# session is mid-response via /session/status (empty object == nothing running).
#
# Clean shutdown = TERM to PID 1 (process-compose), which tears down opencode +
# gitwatch and exits the container -> Fly stops the Machine. gitwatch's debounce
# is seconds while the idle window is minutes, so everything is pushed by then.

PORT="${OPENCODE_PORT:-8080}"
DIR="${WIKI:-/root/llm-wiki}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"
SERVER_USER="${OPENCODE_SERVER_USERNAME:-opencode}"
SERVER_PASS="${OPENCODE_SERVER_PASSWORD:-}"
BASE="http://localhost:${PORT}"

stamp="$(mktemp)"
date +%s >"$stamp"

# Background: subscribe to the per-instance event stream. Heartbeats fire every
# 10s regardless of activity, so they must NOT reset the idle clock; anything
# else (prompts, tool calls, status transitions) counts as activity. Reconnect
# if the stream drops.
(
  while true; do
    curl -sN --user "${SERVER_USER}:${SERVER_PASS}" \
      "${BASE}/event?directory=${DIR}" | while IFS= read -r line; do
      case "$line" in
      *server.heartbeat*) : ;;
      data:*) date +%s >"$stamp" ;;
      esac
    done || true
    sleep 2
  done
) &

idle_secs=$((IDLE_MINUTES * 60))
while true; do
  sleep 60
  now="$(date +%s)"
  last="$(<"$stamp")"
  if ((now - last < idle_secs)); then
    continue
  fi
  # Idle long enough — confirm nothing is mid-response before pulling the plug.
  status="$(curl -s --user "${SERVER_USER}:${SERVER_PASS}" \
    "${BASE}/session/status?directory=${DIR}" || echo '{}')"
  if [ "$(printf '%s' "$status" | jq 'length' 2>/dev/null || echo 1)" = "0" ]; then
    echo "idle ${IDLE_MINUTES}m and no busy sessions -> shutting down"
    # NOT kill -TERM 1: on Fly, PID 1 is Fly's init, not our supervisor. Tell
    # process-compose to shut itself down (it runs its API on PC_PORT); when it
    # exits, Fly's init sees the main command finish and stops the Machine.
    # Fallbacks cover an unreachable API / older process-compose.
    process-compose down -p "${PC_PORT:-8099}" \
      || pkill -TERM process-compose \
      || kill -TERM 1
    exit 0
  fi
done
