#!/usr/bin/env bash
#
# Fails when a reference template in configs/ drifts from the copy that
# hardening.sh embeds as a heredoc (hardening.sh must stay self-contained for
# `curl | bash`, so the content lives in both places).
#
# Usage: tests/check-config-drift.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/hardening.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

# Writes every heredoc body that `cat > <target> <<EOF` writes in hardening.sh
# to <prefix>.1, <prefix>.2, ...
extract_heredocs() {
  awk -v target="$1" -v prefix="$2" '
    !inside && index($0, "cat > " target " <<") { inside = 1; n++; out = prefix "." n; printf "" > out; next }
    inside && $0 == "EOF" { inside = 0; close(out); next }
    inside { print > out }
  ' "$SCRIPT"
}

# Templates use example values and extra comments; compare settings only
normalize() {
  # shellcheck disable=SC2016  # the literal variable names in hardening.sh are what we replace
  sed -e 's/\$SSH_PORT/52211/g' -e 's/\$NOVO_USUARIO/operator/g' -e 's/\$SSH_ALLOW_USERS/operator/g' "$1" | grep -vE '^[[:space:]]*(#|$)' || true
}

# check <target path written by hardening.sh> <template in configs/> <exact|settings>
check() {
  local target="$1" template="$2" mode="$3" body
  rm -f "$TMP"/body.*
  extract_heredocs "$target" "$TMP/body"
  if ! compgen -G "$TMP/body.*" > /dev/null; then
    echo "FAIL $template: hardening.sh has no heredoc writing $target"
    FAILED=1
    return
  fi
  # A target may be written by several heredocs (e.g. sysctl container/full profiles): one must match
  for body in "$TMP"/body.*; do
    if [ "$mode" = exact ]; then
      cmp -s "$body" "$ROOT/$template" && { echo "OK   $template"; return; }
    else
      cmp -s <(normalize "$body") <(normalize "$ROOT/$template") && { echo "OK   $template"; return; }
    fi
  done
  echo "FAIL $template differs from the heredoc writing $target in hardening.sh:"
  if [ "$mode" = exact ]; then
    diff -u "$ROOT/$template" "$body" | sed 's/^/     /' || true
  else
    diff -u <(normalize "$ROOT/$template") <(normalize "$body") | sed 's/^/     /' || true
  fi
  FAILED=1
}

check /etc/ssh/sshd_config.d/00-hardening.conf          configs/00-hardening.conf          settings
check /etc/fail2ban/jail.local                          configs/jail.local                 settings
check /etc/sysctl.d/99-hardening.conf                   configs/99-hardening.conf          settings
check /etc/modprobe.d/hardening.conf                    configs/hardening-modprobe.conf    settings
check /etc/security/limits.d/10-hardening-coredump.conf configs/10-hardening-coredump.conf settings
check /usr/local/bin/ssh-login-alert.sh                 configs/ssh-login-alert.sh         exact

# Every sysctl key set by the template must be saved in the rollback .state file
sed -n '/^HARDENING_SYSCTL_KEYS=(/,/^)/p' "$SCRIPT" | sed '1d;$d' | tr -d ' ' | sort > "$TMP/state_keys"
grep -vE '^[[:space:]]*(#|$)' "$ROOT/configs/99-hardening.conf" | cut -d= -f1 | tr -d ' ' | sort > "$TMP/template_keys"
missing="$(comm -23 "$TMP/template_keys" "$TMP/state_keys")"
if [ -n "$missing" ]; then
  echo "FAIL HARDENING_SYSCTL_KEYS is missing keys set by configs/99-hardening.conf (rollback would not restore them):"
  echo "${missing//$'\n'/$'\n'     }" | sed '1s/^/     /'
  FAILED=1
else
  echo "OK   HARDENING_SYSCTL_KEYS covers configs/99-hardening.conf"
fi

exit "$FAILED"
