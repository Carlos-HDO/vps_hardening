#!/usr/bin/env bash
# /usr/local/bin/ssh-login-alert.sh
# Real-time SSH Login Notification Dispatcher for Telegram, Discord, or Generic Webhooks
# Triggered automatically via PAM session in /etc/pam.d/sshd
# Credentials are read from /etc/vps-hardening/alert.conf (root:root, mode 600)
set -euo pipefail

ALERT_CONF="/etc/vps-hardening/alert.conf"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
WEBHOOK_URL=""

[ "${PAM_TYPE:-}" = "open_session" ] || exit 0
[ -r "$ALERT_CONF" ] || exit 0
# shellcheck source=/dev/null
. "$ALERT_CONF"

# Escape backslashes and double quotes for safe embedding in JSON strings
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

HOST="$(hostname)"
USER="${PAM_USER:-unknown}"
IP="${PAM_RHOST:-unknown}"
DATE="$(date "+%Y-%m-%d %H:%M:%S %Z")"

# 1. Telegram Bot API Dispatch (HTML Format)
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
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

J_HOST="$(json_escape "$HOST")"
J_USER="$(json_escape "$USER")"
J_IP="$(json_escape "$IP")"
J_DATE="$(json_escape "$DATE")"

# 2. Discord Webhook Dispatch
if [[ "$WEBHOOK_URL" =~ discord(app)?\.com/api/webhooks ]]; then
  JSON_PAYLOAD=$(cat <<JSON
{
  "embeds": [{
    "title": "🚨 VPS SSH Login Alert",
    "color": 3066993,
    "fields": [
      {"name": "Server", "value": "${J_HOST}", "inline": true},
      {"name": "User", "value": "${J_USER}", "inline": true},
      {"name": "Remote IP", "value": "${J_IP}", "inline": false},
      {"name": "Timestamp", "value": "${J_DATE}", "inline": false}
    ]
  }]
}
JSON
)
  curl -fsSL -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 &

# 3. Generic Webhook JSON POST
elif [ -n "$WEBHOOK_URL" ]; then
  JSON_PAYLOAD=$(cat <<JSON
{"event":"ssh_login","server":"${J_HOST}","user":"${J_USER}","remote_ip":"${J_IP}","timestamp":"${J_DATE}"}
JSON
)
  curl -fsSL -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 &
fi

exit 0
