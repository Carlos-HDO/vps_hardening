#!/usr/bin/env bash
#
# Quick bootstrap installer for VPS Hardening
# Supports execution locally or piped from curl / wget
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd || true)"

if [ -f "$SCRIPT_DIR/hardening.sh" ]; then
  exec sudo bash "$SCRIPT_DIR/hardening.sh" "$@"
else
  # If executed directly via pipe or standalone
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  echo "[*] Downloading hardening scripts..."
  REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main}"
  curl -fsSL "${REPO_RAW_URL}/hardening.sh" -o "$TMP_DIR/hardening.sh"
  chmod +x "$TMP_DIR/hardening.sh"
  curl -fsSL "${REPO_RAW_URL}/verify.sh" -o "$TMP_DIR/verify.sh" 2>/dev/null || true
  chmod +x "$TMP_DIR/verify.sh" 2>/dev/null || true
  
  exec sudo bash "$TMP_DIR/hardening.sh" "$@"
fi
