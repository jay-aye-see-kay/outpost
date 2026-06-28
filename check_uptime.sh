#!/usr/bin/env bash
# How much of the last 24h was the Fly machine actually awake?
#
# Fly's `fly_instance_up` metric is only scraped WHILE the machine is up, so its
# value is always 1 and avg_over_time is useless (always 100%). Instead we count
# how many samples exist: samples x scrape-interval = awake time. Gaps = asleep.
#
# Reads Fly's hosted Prometheus. Run it from your normal shell any time (the
# machine can be asleep when you run this — we're querying history, not it).
set -euo pipefail

ORG="${FLY_ORG:-personal}"
APP="${FLY_APP:-outpost-wiki}"
WINDOW="${WINDOW:-24h}"
# Fly scrapes ~every 15s. Override if calibration (below) says otherwise.
INTERVAL="${SCRAPE_INTERVAL:-15}"

# Mint a short-lived read-only token (no interactive org prompt).
TOKEN="$(flyctl tokens create readonly --org "$ORG" 2>/dev/null | grep '^FlyV1')"
if [ -z "$TOKEN" ]; then
  echo "error: couldn't mint a Fly token (is flyctl logged in?)" >&2
  exit 1
fi

query() {
  curl -s -G -H "Authorization: $TOKEN" \
    "https://api.fly.io/prometheus/$ORG/api/v1/query" \
    --data-urlencode "query=$1"
}

# Pull a single scalar out of a Prometheus vector response (0 if empty).
scalar() { jq -r '[.data.result[].value[1] | tonumber] | add // 0'; }

# Total awake samples across all instances of the app in the window.
samples="$(query "sum(count_over_time(fly_instance_up{app=\"$APP\"}[$WINDOW]))" | scalar)"

awake_secs="$(awk -v s="$samples" -v i="$INTERVAL" 'BEGIN{printf "%.0f", s*i}')"
total_secs="$(awk -v w="$WINDOW" 'BEGIN{
  n=w; sub(/[a-z]/,"",n);
  if (w ~ /h$/) print n*3600; else if (w ~ /m$/) print n*60; else if (w ~ /d$/) print n*86400; else print n
}')"
pct="$(awk -v a="$awake_secs" -v t="$total_secs" 'BEGIN{printf "%.1f", (t>0)?a/t*100:0}')"
hrs="$(awk -v a="$awake_secs" 'BEGIN{printf "%.1f", a/3600}')"

echo "app:      $APP  (last $WINDOW, ~${INTERVAL}s scrape)"
echo "awake:    ${hrs}h  (${pct}% online)"
echo "asleep:   $(awk -v t="$total_secs" -v a="$awake_secs" 'BEGIN{printf "%.1f", (t-a)/3600}')h  ($(awk -v p="$pct" 'BEGIN{printf "%.1f", 100-p}')% asleep)"
echo
echo "per-instance awake time:"
query "count_over_time(fly_instance_up{app=\"$APP\"}[$WINDOW])" \
  | jq -r --arg i "$INTERVAL" '
      .data.result[]
      | "  \(.metric.instance)  \((.value[1]|tonumber) * ($i|tonumber) / 3600 | .*10 | round / 10)h"' \
  | sort
