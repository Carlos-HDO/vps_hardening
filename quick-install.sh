#!/usr/bin/env bash
#
# Quick bootstrap installer for VPS Hardening
# Suporta execução via pipe ou local
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd || true)"

if [ -f "$SCRIPT_DIR/hardening.sh" ]; then
  exec sudo bash "$SCRIPT_DIR/hardening.sh" "$@"
else
  # Se for executado via pipe direto ou standalone
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  echo "[*] Baixando script de hardening..."
  # URL de fallback ou repositório configurado
  REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main}"
  curl -fsSL "${REPO_RAW_URL}/hardening.sh" -o "$TMP_DIR/hardening.sh"
  chmod +x "$TMP_DIR/hardening.sh"
  
  exec sudo bash "$TMP_DIR/hardening.sh" "$@"
fi
