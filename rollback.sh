#!/usr/bin/env bash
#
# Quick Rollback Utility for VPS Hardening
# Restores previous system configuration from pre-hardening snapshot
#
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "\033[1;31m[-] ERROR:\033[0m This rollback script must be executed as root (use sudo)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd || true)"

if [ -f "$SCRIPT_DIR/hardening.sh" ]; then
  exec bash "$SCRIPT_DIR/hardening.sh" --rollback "$@"
else
  # Direct fallback rollback from /var/backups/vps_hardening
  BACKUP_DIR="/var/backups/vps_hardening"
  TARGET_BACKUP="${1:-}"

  if [ -z "$TARGET_BACKUP" ]; then
    if [ -f "$BACKUP_DIR/latest.tar.gz" ]; then
      TARGET_BACKUP="$BACKUP_DIR/latest.tar.gz"
    elif compgen -G "$BACKUP_DIR/hardening_backup_*.tar.gz" > /dev/null; then
      TARGET_BACKUP=$(ls -t "$BACKUP_DIR"/hardening_backup_*.tar.gz 2>/dev/null | head -n 1)
    fi
  fi

  if [ -z "$TARGET_BACKUP" ] || [ ! -f "$TARGET_BACKUP" ]; then
    echo "[-] ERROR: No rollback backup archive found in '$BACKUP_DIR'." >&2
    exit 1
  fi

  echo "[*] Restoring files from $TARGET_BACKUP..."
  tar -xzf "$TARGET_BACKUP" -C /
  sysctl --system >/dev/null 2>&1 || true
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  echo "[✔] Rollback completed successfully."
fi
