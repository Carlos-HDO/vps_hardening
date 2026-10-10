#!/usr/bin/env bash
#
# Quick bootstrap installer for VPS Hardening
# Downloads a tagged release, verifies it against the release SHA256SUMS and
# runs hardening.sh. All arguments are passed through to hardening.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/v1.0.0/quick-install.sh | sudo bash
#   curl -fsSL .../quick-install.sh | sudo bash -s -- -u operator -k "gh:username" --password-hash '<hash>' -y
#
# Environment:
#   VPS_HARDENING_REF            Release tag to install (default: v1.0.0)
#   VPS_HARDENING_SKIP_CHECKSUM  Set to 1 to skip SHA256 verification (e.g. for an untagged branch)
#
set -euo pipefail

REPO="carlos-hdo/vps_hardening"
REF="${VPS_HARDENING_REF:-v1.0.0}"
FILES=(hardening.sh verify.sh rollback.sh)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd || true)"

# Running from a clone: use the local files
if [ -f "$SCRIPT_DIR/hardening.sh" ]; then
  exec sudo bash "$SCRIPT_DIR/hardening.sh" "$@"
fi

WORK_DIR="$(mktemp -d)"
cleanup_on_error() { rm -rf "$WORK_DIR"; }
trap cleanup_on_error ERR

echo "[*] Downloading VPS Hardening ${REF}..."
for f in "${FILES[@]}"; do
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/${REF}/${f}" -o "$WORK_DIR/$f"
done

if [ "${VPS_HARDENING_SKIP_CHECKSUM:-0}" = "1" ]; then
  echo "[!] WARNING: SHA256 verification skipped (VPS_HARDENING_SKIP_CHECKSUM=1)." >&2
else
  if ! curl -fsSL "https://github.com/${REPO}/releases/download/${REF}/SHA256SUMS" -o "$WORK_DIR/SHA256SUMS"; then
    echo "[-] ERROR: Could not download SHA256SUMS for '${REF}'. Use a published release tag," >&2
    echo "    or set VPS_HARDENING_SKIP_CHECKSUM=1 to run unverified code at your own risk." >&2
    rm -rf "$WORK_DIR"
    exit 1
  fi
  for f in "${FILES[@]}"; do
    if ! grep -qE "^[0-9a-f]{64}  ${f}\$" "$WORK_DIR/SHA256SUMS"; then
      echo "[-] ERROR: ${f} is not listed in SHA256SUMS for '${REF}'." >&2
      rm -rf "$WORK_DIR"
      exit 1
    fi
  done
  if ! (cd "$WORK_DIR" && sha256sum --check --ignore-missing --quiet SHA256SUMS); then
    echo "[-] ERROR: SHA256 checksum mismatch. The downloaded files were NOT executed." >&2
    rm -rf "$WORK_DIR"
    exit 1
  fi
  echo "[✔] SHA256 checksums verified for ${FILES[*]}."
fi

chmod +x "$WORK_DIR"/*.sh
exec sudo bash "$WORK_DIR/hardening.sh" "$@"
