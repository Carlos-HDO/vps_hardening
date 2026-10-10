#!/usr/bin/env bash
#
# ==============================================================================
# VPS Hardening Rollback Utility
# Restores the pre-hardening system state captured by hardening.sh:
#   - restores configuration files from the snapshot archive
#   - removes files created by the hardening run (.created manifest)
#   - restores services, firewall, sysctl, /dev/shm and default accounts (.state)
#
# Usage:
#   sudo ./rollback.sh [--yes] [/var/backups/vps_hardening/hardening_backup_<ts>.tar.gz]
#   sudo hardening-rollback [--yes] [archive]
#   sudo ./hardening.sh --rollback [archive]
# ==============================================================================

set -uo pipefail

VERSION="1.0.1"

C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_BOLD="\033[1m"

log_info()    { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
log_success() { echo -e "${C_GREEN}[✔]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}[-] ERROR:${C_RESET} $*" >&2; }

BACKUP_DIR="/var/backups/vps_hardening"
ASSUME_YES=false
TARGET_BACKUP=""

show_help() {
  cat <<EOF
Usage: sudo $0 [options] [archive]

Restores the system to the state captured before the first hardening run.

Arguments:
  archive          Snapshot archive to restore (default: ${BACKUP_DIR}/latest.tar.gz)

Options:
  -y, --yes        Do not ask for confirmation
  -V, --version    Print the version and exit
  -h, --help       Display this help message
EOF
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=true; shift ;;
    -h|--help) show_help ;;
    -V|--version) echo "vps_hardening rollback ${VERSION}"; exit 0 ;;
    -*)        log_error "Unknown parameter: $1"; echo "Run '$0 --help' for usage." >&2; exit 1 ;;
    *)         TARGET_BACKUP="$1"; shift ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_error "This rollback script must be executed as root (use sudo)."
  exit 1
fi

echo ""
echo -e "${C_BOLD}==========================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}          VPS HARDENING SYSTEM ROLLBACK${C_RESET}"
echo -e "${C_BOLD}==========================================================${C_RESET}"
echo ""

# ------------------------------------------------------------------
# Locate snapshot, manifest and state files
# ------------------------------------------------------------------
if [ -z "$TARGET_BACKUP" ]; then
  if [ -e "$BACKUP_DIR/latest.tar.gz" ]; then
    TARGET_BACKUP="$BACKUP_DIR/latest.tar.gz"
  elif compgen -G "$BACKUP_DIR/hardening_backup_*.tar.gz" > /dev/null; then
    # Oldest snapshot = state before the first hardening run
    TARGET_BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -name 'hardening_backup_*.tar.gz' | sort | head -n 1)"
  fi
fi

if [ -z "$TARGET_BACKUP" ] || [ ! -f "$TARGET_BACKUP" ]; then
  log_error "No rollback backup archive found in '$BACKUP_DIR'."
  echo "Usage: sudo $0 [--yes] [/path/to/hardening_backup.tar.gz]" >&2
  exit 1
fi

TARGET_BACKUP="$(readlink -f "$TARGET_BACKUP")"
SNAPSHOT_BASE="${TARGET_BACKUP%.tar.gz}"
MANIFEST_FILE="${SNAPSHOT_BASE}.created"
STATE_FILE="${SNAPSHOT_BASE}.state"

LEGACY_SNAPSHOT=false
if [ ! -f "$MANIFEST_FILE" ] || [ ! -f "$STATE_FILE" ]; then
  LEGACY_SNAPSHOT=true
fi

log_warn "Target snapshot: ${C_BOLD}${TARGET_BACKUP}${C_RESET}"
if [ "$LEGACY_SNAPSHOT" = true ]; then
  log_warn "This snapshot was created by an older version (no .created/.state files)."
  log_warn "Only configuration files will be restored; files created by hardening and service states will NOT be reverted."
fi

if [ "$ASSUME_YES" = false ]; then
  confirm_rb=""
  if { : < /dev/tty; } 2>/dev/null; then
    read -r -p "Are you sure you want to restore previous system configurations? [y/N]: " confirm_rb < /dev/tty || true
  else
    log_error "No terminal available for confirmation. Re-run with --yes."
    exit 1
  fi
  if [[ ! "$confirm_rb" =~ ^[YySs]$ ]]; then
    log_info "Rollback aborted by user."
    exit 0
  fi
fi

# State file helper: prints the value stored for KEY (empty if absent)
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  grep -m1 -E "^$1=" "$STATE_FILE" | cut -d= -f2-
}

# Disarm a pending auto-revert timer (this rollback supersedes it)
systemctl stop vps-hardening-autorevert.timer >/dev/null 2>&1 || true

# ------------------------------------------------------------------
# 1. Restore configuration files
# ------------------------------------------------------------------
log_info "Restoring configuration files from snapshot..."
if ! tar -xzpf "$TARGET_BACKUP" -C /; then
  log_error "Failed to extract $TARGET_BACKUP. Aborting rollback (no further changes made)."
  exit 1
fi

# ------------------------------------------------------------------
# 2. Remove files created by the hardening run
# ------------------------------------------------------------------
if [ "$LEGACY_SNAPSHOT" = false ]; then
  log_info "Removing files created by the hardening run..."
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      if rmdir "$path" 2>/dev/null; then
        log_info "  removed directory $path"
      fi
    elif [ -e "$path" ] || [ -L "$path" ]; then
      rm -f "$path" && log_info "  removed $path"
    fi
  done < "$MANIFEST_FILE"
fi

# ------------------------------------------------------------------
# 3. Restore cloud provider default accounts
# ------------------------------------------------------------------
if [ "$LEGACY_SNAPSHOT" = false ]; then
  while IFS='=' read -r key value; do
    case "$key" in account.*) ;; *) continue ;; esac
    u="${key#account.}"
    id "$u" &>/dev/null || continue
    IFS='|' read -r acc_shell acc_pw acc_keys <<< "$value"
    if [ -n "$acc_shell" ]; then
      usermod -s "$acc_shell" "$u" 2>/dev/null || true
    fi
    if [ "$acc_pw" != "L" ]; then
      usermod -U "$u" >/dev/null 2>&1 || true
    fi
    u_home="$(getent passwd "$u" | cut -d: -f6)"
    if [ "$acc_keys" = "yes" ] && [ -f "$u_home/.ssh/authorized_keys.disabled" ] && [ ! -e "$u_home/.ssh/authorized_keys" ]; then
      mv "$u_home/.ssh/authorized_keys.disabled" "$u_home/.ssh/authorized_keys"
    fi
    log_info "Default account '$u' restored (shell: ${acc_shell})."
  done < "$STATE_FILE"
fi

# ------------------------------------------------------------------
# 4. Kernel parameters and /dev/shm
# ------------------------------------------------------------------
log_info "Reloading kernel parameters..."
systemctl daemon-reload >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true

if [ "$LEGACY_SNAPSHOT" = false ]; then
  while IFS='=' read -r key value; do
    case "$key" in sysctl.*) ;; *) continue ;; esac
    sysctl -q -w "${key#sysctl.}=${value}" >/dev/null 2>&1 || true
  done < "$STATE_FILE"

  shm_opts="$(state_get shm.options)"
  if [ -n "$shm_opts" ]; then
    remount_opts="remount,${shm_opts}"
    [[ ",$shm_opts," == *",noexec,"* ]] || remount_opts+=",exec"
    [[ ",$shm_opts," == *",nosuid,"* ]] || remount_opts+=",suid"
    [[ ",$shm_opts," == *",nodev,"* ]]  || remount_opts+=",dev"
    mount -o "$remount_opts" /dev/shm 2>/dev/null || log_warn "Could not remount /dev/shm (original options apply after reboot)."
  fi
fi

# ------------------------------------------------------------------
# 5. Services (fail2ban, auditd, unattended-upgrades)
# ------------------------------------------------------------------
restore_unit_state() {
  local unit="$1"
  local enabled active
  enabled="$(state_get "service.${unit}.enabled")"
  active="$(state_get "service.${unit}.active")"
  case "$enabled" in
    enabled)  systemctl enable "$unit" >/dev/null 2>&1 || true ;;
    # not-found: the package was installed by hardening, so keep it off at boot
    disabled|not-found) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    masked)   systemctl mask "$unit" >/dev/null 2>&1 || true ;;
  esac
  if [ "$active" = "active" ]; then
    systemctl restart "$unit" >/dev/null 2>&1 || true
  elif [ -n "$active" ]; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
  fi
}

if [ "$LEGACY_SNAPSHOT" = false ]; then
  log_info "Restoring service states (fail2ban, auditd, unattended-upgrades)..."
  for unit in fail2ban auditd unattended-upgrades; do
    restore_unit_state "$unit"
  done
else
  systemctl restart fail2ban >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------
# 6. Firewall (before SSH, so the original SSH port is reachable)
# ------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw_state="$(state_get ufw.active)"
  if [ "$LEGACY_SNAPSHOT" = false ] && [ "$ufw_state" != "yes" ]; then
    log_info "UFW was not active before hardening. Disabling firewall..."
    ufw --force disable >/dev/null 2>&1 || true
  elif ufw status 2>/dev/null | grep -q "Status: active"; then
    log_info "Reloading UFW with restored rules..."
    ufw reload >/dev/null 2>&1 || true
  fi
fi

# ------------------------------------------------------------------
# 7. OpenSSH (validated before any restart)
# ------------------------------------------------------------------
log_info "Validating restored OpenSSH configuration..."
mkdir -p /run/sshd 2>/dev/null || true
if sshd -t 2>/dev/null; then
  if [ "$LEGACY_SNAPSHOT" = false ]; then
    for unit in ssh.service ssh.socket; do
      case "$(state_get "service.${unit}.enabled")" in
        enabled)  systemctl enable "$unit" >/dev/null 2>&1 || true ;;
        disabled) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
      esac
    done
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ "$(state_get service.ssh.socket.active)" = "active" ]; then
    # Socket activation (Ubuntu 22.10+): hand the listening port back to ssh.socket.
    # ssh.service uses KillMode=process, so open sessions survive the stop.
    systemctl stop ssh.service >/dev/null 2>&1 || true
    systemctl restart ssh.socket >/dev/null 2>&1 || true
  else
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
  fi
  log_success "SSH service restarted with restored configuration."
else
  log_warn "sshd configuration check reported errors. SSH was NOT restarted — fix /etc/ssh and restart it manually."
fi

echo ""
log_success "Rollback completed! System configuration restored from: $TARGET_BACKUP"
admin_user="$(state_get admin.user)"
if [ -n "$admin_user" ] && [ "$(state_get admin.user_existed)" = "no" ]; then
  log_info "Note: the admin user '${admin_user}' created by hardening was kept (remove with: userdel -r ${admin_user})."
fi
log_info "Note: packages installed by hardening (ufw, fail2ban, auditd, unattended-upgrades, ...) were kept."
exit 0
