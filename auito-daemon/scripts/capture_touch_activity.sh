#!/bin/sh
set -eu

PORT="${AUITO_PORT:-8876}"
INTERVAL="${AUITO_CAPTURE_INTERVAL:-0.25}"
OUT="${1:-/tmp/auito-touch-capture-$(date +%Y%m%d-%H%M%S).jsonl}"

if [ "${2:-}" != "" ]; then
  INTERVAL="$2"
fi

echo "Capturing touch activity from http://127.0.0.1:${PORT} every ${INTERVAL}s"
echo "Writing JSONL to ${OUT}"
echo "Press Ctrl+C to stop."

cleanup() {
  echo "Capture saved to ${OUT}"
  exit 0
}
trap cleanup INT TERM

prev_cb=""

while :; do
  ts="$(date +%s)"
  sender="$(curl -fsS "http://127.0.0.1:${PORT}/touch/senderid" 2>/dev/null || true)"

  if [ -z "$sender" ]; then
    sleep "$INTERVAL"
    continue
  fi

  cb="$(printf '%s' "$sender" | sed -n 's/.*"callbackCount":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  evt="$(printf '%s' "$sender" | sed -n 's/.*"lastEventType":[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1)"

  if [ -z "$cb" ]; then
    sleep "$INTERVAL"
    continue
  fi

  if [ "$cb" != "$prev_cb" ]; then
    diag="$(curl -fsS "http://127.0.0.1:${PORT}/nonax/diagnostics" 2>/dev/null || printf '{}')"
    # Keep one JSON object per output line (valid JSONL).
    sender_compact="$(printf '%s' "$sender" | tr -d '\r\n')"
    diag_compact="$(printf '%s' "$diag" | tr -d '\r\n')"
    printf '{"ts":%s,"callbackCount":%s,"lastEventType":%s,"sender":%s,"diagnostics":%s}\n' \
      "$ts" "$cb" "${evt:-null}" "$sender_compact" "$diag_compact" >> "$OUT"
    echo "touch callbacks=${cb} lastEventType=${evt:-unknown}"
    prev_cb="$cb"
  fi

  sleep "$INTERVAL"
done
