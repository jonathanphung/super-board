#!/usr/bin/env bash
# super-qa-notify.sh — one-line Telegram status update from the QA loop.
#
#   .claude/bin/super-qa-notify.sh "✅ Iter 3 done — 1 bug, 5 items processed"
#
# Credentials come from TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID in the
# environment, falling back to the repo's gitignored .env.local. If neither
# is configured this is a silent no-op (exit 0) — the loop must never halt
# because notifications are unset; the terminal log is the fallback channel.

set -euo pipefail

MSG="${1:-}"
[ -n "$MSG" ] || { echo "usage: $0 \"message\"" >&2; exit 64; }

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  ENV_FILE="$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.env.local"
  if [ -f "$ENV_FILE" ]; then
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE" | tail -1)}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(sed -n 's/^TELEGRAM_CHAT_ID=//p' "$ENV_FILE" | tail -1)}"
  fi
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  echo "[super-qa-notify] telegram not configured — skipping: $MSG" >&2
  exit 0
fi

RESP=$(curl -s --max-time 15 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode text="$MSG" || true)

if echo "$RESP" | grep -q '"ok":true'; then
  exit 0
fi
echo "[super-qa-notify] send failed (continuing): ${RESP:-no response}" >&2
exit 0
