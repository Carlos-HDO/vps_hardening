#!/usr/bin/env bash
# /usr/local/bin/ssh-login-alert.sh
# Real-time SSH Login Notification Dispatcher for Telegram, Discord, or Generic Webhooks
# Triggered automatically via PAM session in /etc/pam.d/sshd
set -euo pipefail

# Configuration parameters:
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

if [ "${PAM_TYPE:-}" = "open_session" ]; then
  HOST="$(hostname)"
  USER="${PAM_USER:-unknown}"
  IP="${PAM_RHOST:-unknown}"
  DATE="$(date "+%Y-%m-%d %H:%M:%S %Z")"

  # 1. Telegram Bot API Dispatch (HTML Format)
  if [ -n "$TG_BOT_TOKEN" ] && [ "$TG_BOT_TOKEN" != "none" ] && [ -n "$TG_CHAT_ID" ] && [ "$TG_CHAT_ID" != "none" ]; then
    TG_MSG="🚨 <b>VPS SSH LOGIN ALERT</b>
━━━━━━━━━━━━━━━━━━
🖥️ <b>Server:</b> <code>${HOST}</code>
👤 <b>User:</b> <code>${USER}</code>
🌐 <b>Remote IP:</b> <code>${IP}</code>
🕒 <b>Date:</b> <code>${DATE}</code>
━━━━━━━━━━━━━━━━━━
⚠️ <i>If this was not you, verify active sessions immediately!</i>"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "parse_mode=HTML" \
      --data-urlencode "text=${TG_MSG}" >/dev/null 2>&1 &
  fi

  # 2. Discord Webhook Dispatch
  if [[ "$WEBHOOK_URL" =~ discord(app)?\.com/api/webhooks ]]; then
    JSON_PAYLOAD=$(cat <<JSON
{
  "embeds": [{
    "title": "🚨 VPS SSH Login Alert",
    "color": 3066993,
    "fields": [
      {"name": "Server", "value": "${HOST}", "inline": true},
      {"name": "User", "value": "${USER}", "inline": true},
      {"name": "Remote IP", "value": "${IP}", "inline": false},
      {"name": "Timestamp", "value": "${DATE}", "inline": false}
    ]
  }]
}
JSON
)
    curl -fsSL -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 &

  # 3. Generic Webhook JSON POST
  elif [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "none" ]; then
    JSON_PAYLOAD=$(cat <<JSON
{"event":"ssh_login","server":"${HOST}","user":"${USER}","remote_ip":"${IP}","timestamp":"${DATE}"}
JSON
)
    curl -fsSL -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 &
  fi
fi

exit 0
