#!/usr/bin/env bash
#
# ==============================================================================
# VPS Hardening Automation Tool
# Compatible with Ubuntu 20.04/22.04/24.04 LTS and Debian 11/12+
#
# Usage Modes:
#   1) Interactive (direct execution or via curl/wget | bash):
#      sudo ./hardening.sh
#      curl -fsSL <URL>/hardening.sh | sudo bash
#
#   2) Positional arguments:
#      sudo ./hardening.sh <user> "<ssh_public_key>" [ssh_port] [timezone]
#
#   3) Named flags:
#      sudo ./hardening.sh -u operator -k "ssh-ed25519 AAAA..." -p 52211 -y
# ==============================================================================

set -euo pipefail

VERSION="1.0.0"

# Environment variables to avoid interactive package prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Terminal colors and formatting
C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_BOLD="\033[1m"
C_DIM="\033[2m"

log_info()    { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
log_step()    { echo -e "${C_CYAN}[+]${C_RESET} ${C_BOLD}$*${C_RESET}"; }
log_success() { echo -e "${C_GREEN}[✔]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}[-] ERROR:${C_RESET} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" &>/dev/null && pwd || true)"
# Helper scripts are fetched from the release matching this script (used only when not running from a clone)
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/carlos-hdo/vps_hardening/v${VERSION}}"

# Helper function for safe terminal input (even when piped from `curl ... | bash`)
read_input() {
  local prompt="$1"
  local varname="$2"
  local default_val="${3:-}"
  local value=""

  if { : < /dev/tty; } 2>/dev/null; then
    read -r -p "$(echo -e "$prompt")" value < /dev/tty || true
  else
    read -r -p "$(echo -e "$prompt")" value || true
  fi

  if [ -z "$value" ] && [ -n "$default_val" ]; then
    value="$default_val"
  fi
  printf -v "$varname" '%s' "$value"
}

# ------------------------------------------------------------------
# Quick Help Check (-h / --help)
# ------------------------------------------------------------------
show_help() {
  cat <<EOF
Usage: sudo $0 [options] or sudo $0 <user> "<ssh_key>" [port] [timezone]

Options:
  -u, --user <username>       Name of the new administrative user
  -k, --key "<ssh_key>"       Authorized public SSH key (raw string, gh:username, or URL)
  -p, --port <port>           Custom SSH port (1024-65535, default: 52211)
  -t, --timezone <tz>         System timezone (e.g., UTC, America/New_York, America/Sao_Paulo)
  -a, --allow-ports <ports>   Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp)
  --password-hash '<hash>'    Crypt hash for the admin user's sudo password, used when the account
                              has no password (required with -y; generate with: openssl passwd -6)
  --safety-timer              Arm the auto-revert timer even with -y (default: on in interactive mode)
  --no-safety-timer           Do not arm the auto-revert timer
  --skip-upgrade              Skip 'apt-get upgrade' of installed packages in Phase 1
  --dry-run                   Simulate actions without making actual changes to the system
  --rollback [archive]        Restore system configuration from pre-hardening snapshot
  --tg-token <token>          Telegram Bot Token (from @BotFather) for login alerts
  --tg-chat <chat_id>         Telegram Chat ID (from @userinfobot) for login alerts
  -w, --webhook <url>         Discord/Custom Webhook URL for real-time SSH login alerts
  --audit, --lynis            Run Lynis security audit scan after hardening
  --no-verify                 Skip automatic post-hardening verification tests
  -y, --yes                   Skip interactive confirmation prompt
  -V, --version               Print the version and exit
  -h, --help                  Display this help message

Examples:
  sudo $0 operator "ssh-ed25519 AAAAC3... vps-access" 52211
  sudo $0 -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -a 80,443 --tg-token "..." --tg-chat "..." -y
  sudo $0 -u operator -k "gh:username" --password-hash "\$(openssl passwd -6)" -y
  sudo $0 --dry-run           # Test run simulation
  sudo $0 --rollback          # Restore previous configuration from latest backup
EOF
  exit 0
}

for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    show_help
  elif [ "$arg" = "-V" ] || [ "$arg" = "--version" ]; then
    echo "vps_hardening ${VERSION}"
    exit 0
  fi
done

# ------------------------------------------------------------------
# Root Privilege Check (relaxed for --dry-run)
# ------------------------------------------------------------------
IS_EARLY_DRY_RUN=false
for _arg in "$@"; do
  if [ "$_arg" = "--dry-run" ]; then
    IS_EARLY_DRY_RUN=true
    break
  fi
done

if [ "$IS_EARLY_DRY_RUN" = false ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_error "This script must be executed as root (use sudo)."
  echo "Example: sudo $0"
  exit 1
elif [ "$IS_EARLY_DRY_RUN" = true ] && [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_warn "Running in DRY-RUN mode without root privileges. No system changes will be made."
fi

# ------------------------------------------------------------------
# Default Configuration Variables
# ------------------------------------------------------------------
NOVO_USUARIO="${HARDENING_USER:-}"
CHAVE_SSH="${HARDENING_SSH_KEY:-}"
SSH_PORT="${HARDENING_SSH_PORT:-52211}"
TIMEZONE="${HARDENING_TIMEZONE:-America/Sao_Paulo}"
ALLOW_PORTS="${HARDENING_ALLOW_PORTS:-}"
DRY_RUN=false
DO_ROLLBACK=false
ROLLBACK_FILE=""
TG_BOT_TOKEN="${HARDENING_TG_TOKEN:-}"
TG_CHAT_ID="${HARDENING_TG_CHAT_ID:-}"
WEBHOOK_URL="${HARDENING_WEBHOOK_URL:-}"
RUN_AUDIT="${HARDENING_RUN_AUDIT:-false}"
RUN_VERIFY=true
SKIP_UPGRADE="${HARDENING_SKIP_UPGRADE:-false}"
PASSWORD_HASH="${HARDENING_PASSWORD_HASH:-}"
SAFETY_TIMER="${HARDENING_SAFETY_TIMER:-auto}"
SAFETY_TIMER_MINUTES="${HARDENING_SAFETY_TIMER_MINUTES:-10}"
SAFETY_TIMER_UNIT="vps-hardening-autorevert"
SAFETY_TIMER_ARMED=false
LYNIS_SCORE="N/A"
ASSUME_YES=false
ROLLBACK_SNAPSHOT_PATH=""
IS_CONTAINER=false
VIRT_ENV="standard"

detect_virtualization() {
  IS_CONTAINER=false
  VIRT_ENV="standard"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local detected_virt
    detected_virt="$(systemd-detect-virt 2>/dev/null)" || detected_virt="none"
    if systemd-detect-virt --container >/dev/null 2>&1; then
      IS_CONTAINER=true
      VIRT_ENV="$detected_virt"
    else
      VIRT_ENV="$detected_virt"
    fi
  elif [ -f /.dockerenv ]; then
    IS_CONTAINER=true
    VIRT_ENV="docker"
  elif [ -d /proc/vz ]; then
    IS_CONTAINER=true
    VIRT_ENV="openvz"
  fi
}
detect_virtualization

# ------------------------------------------------------------------
# Rollback Snapshot (created only on the first run)
# ------------------------------------------------------------------
BACKUP_DIR="/var/backups/vps_hardening"

# Paths archived in the snapshot (restored by rollback.sh)
SNAPSHOT_PATHS=(
  /etc/ssh
  /etc/pam.d/sshd
  /etc/sysctl.d
  /etc/fstab
  /etc/default/ufw
  /etc/ufw
  /etc/fail2ban
  /etc/security/limits.d
  /etc/modprobe.d
  /etc/modules-load.d
  /etc/apt/apt.conf.d/20auto-upgrades
  /etc/systemd/coredump.conf.d
  /usr/local/bin/ssh-login-alert.sh
  /etc/vps-hardening
)

# Files this script may create. Those absent before the first run are listed in
# the .created manifest and deleted by rollback.sh.
HARDENING_MANAGED_FILES=(
  /etc/ssh/sshd_config.bak
  /etc/ssh/sshd_config.d/00-hardening.conf
  /etc/pam.d/sshd.bak
  /etc/fail2ban/jail.local
  /etc/sysctl.d/99-hardening.conf
  /etc/modules-load.d/bbr.conf
  /etc/apt/apt.conf.d/20auto-upgrades
  /etc/security/limits.d/10-hardening-coredump.conf
  /etc/systemd/coredump.conf.d/disable.conf
  /etc/modprobe.d/hardening.conf
  /usr/local/bin/ssh-login-alert.sh
  /etc/vps-hardening/alert.conf
)

# Directories this script may create (removed by rollback.sh only if empty)
HARDENING_MANAGED_DIRS=(
  /etc/vps-hardening
  /etc/systemd/coredump.conf.d
  /etc/ssh/sshd_config.d
)

# Kernel parameters changed in Phase 6 (original values saved in the .state file)
HARDENING_SYSCTL_KEYS=(
  net.ipv4.conf.all.accept_source_route
  net.ipv4.conf.default.accept_source_route
  net.ipv6.conf.all.accept_source_route
  net.ipv4.conf.all.accept_redirects
  net.ipv4.conf.default.accept_redirects
  net.ipv6.conf.all.accept_redirects
  net.ipv4.conf.all.send_redirects
  net.ipv4.conf.all.rp_filter
  net.ipv4.conf.default.rp_filter
  net.ipv4.conf.all.log_martians
  net.ipv4.tcp_syncookies
  net.ipv4.icmp_echo_ignore_broadcasts
  net.ipv4.icmp_ignore_bogus_error_responses
  kernel.randomize_va_space
  kernel.kptr_restrict
  kernel.dmesg_restrict
  fs.suid_dumpable
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
)

DEFAULT_CLOUD_ACCOUNTS=(ubuntu debian admin centos)

write_snapshot_state() {
  local unit enabled active key value u u_shell u_pw u_home u_keys

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "ufw.active=yes"
  else
    echo "ufw.active=no"
  fi

  for unit in ssh.service ssh.socket fail2ban auditd unattended-upgrades; do
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    echo "service.${unit}.enabled=${enabled:-not-found}"
    echo "service.${unit}.active=${active:-inactive}"
  done

  for key in "${HARDENING_SYSCTL_KEYS[@]}"; do
    if value="$(sysctl -n "$key" 2>/dev/null)"; then
      echo "sysctl.${key}=${value}"
    fi
  done

  echo "shm.options=$(findmnt -no OPTIONS /dev/shm 2>/dev/null || true)"

  for u in "${DEFAULT_CLOUD_ACCOUNTS[@]}"; do
    if id "$u" &>/dev/null && [ "$u" != "$NOVO_USUARIO" ]; then
      u_shell="$(getent passwd "$u" | cut -d: -f7)"
      u_pw="$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || true)"
      u_home="$(getent passwd "$u" | cut -d: -f6)"
      u_keys=no
      [ -f "$u_home/.ssh/authorized_keys" ] && u_keys=yes
      echo "account.${u}=${u_shell}|${u_pw}|${u_keys}"
    fi
  done

  echo "admin.user=${NOVO_USUARIO}"
  if id "$NOVO_USUARIO" &>/dev/null; then
    echo "admin.user_existed=yes"
  else
    echo "admin.user_existed=no"
  fi
}

create_rollback_snapshot() {
  local latest="$BACKUP_DIR/latest.tar.gz"

  if [ -e "$latest" ]; then
    ROLLBACK_SNAPSHOT_PATH="$(readlink -f "$latest")"
    log_info "Original pre-hardening snapshot already exists: ${ROLLBACK_SNAPSHOT_PATH}"
    log_info "Keeping it (snapshots are only created on the first run, so rollback always returns to the original state)."
    return 0
  fi

  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local snapshot_base="${BACKUP_DIR}/hardening_backup_${timestamp}"
  local snapshot_archive="${snapshot_base}.tar.gz"

  log_info "Creating pre-hardening rollback snapshot..."
  install -d -m 700 -o root -g root "$BACKUP_DIR"

  local files_to_backup=() item
  for item in "${SNAPSHOT_PATHS[@]}"; do
    [ -e "$item" ] && files_to_backup+=("${item#/}")
  done

  # The archive contains SSH host private keys: keep it root-only
  local tar_rc=0
  (umask 077 && tar -czpf "$snapshot_archive" -C / "${files_to_backup[@]}" 2>/dev/null) || tar_rc=$?
  # GNU tar exits 1 when files changed while being read; anything higher is fatal
  if [ "$tar_rc" -gt 1 ] || [ ! -s "$snapshot_archive" ]; then
    log_error "Failed to create rollback snapshot at $snapshot_archive. Aborting before any change."
    exit 1
  fi

  local manifest_paths=("${HARDENING_MANAGED_FILES[@]}") conf
  for conf in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$conf" ] && manifest_paths+=("${conf}.bak")
  done
  (
    umask 077
    for item in "${manifest_paths[@]}" "${HARDENING_MANAGED_DIRS[@]}"; do
      [ -e "$item" ] || echo "$item"
    done > "${snapshot_base}.created"
    write_snapshot_state > "${snapshot_base}.state"
  )

  ln -sfn "$snapshot_archive" "$latest"
  ROLLBACK_SNAPSHOT_PATH="$snapshot_archive"
  log_success "Pre-hardening snapshot created at: $snapshot_archive"
}

# Rollback lives in rollback.sh (single implementation). Prefer the copy next to
# this script, then the installed helper.
run_rollback_tool() {
  local tool=""
  if [ -f "$SCRIPT_DIR/rollback.sh" ]; then
    tool="$SCRIPT_DIR/rollback.sh"
  elif [ -x /usr/local/sbin/hardening-rollback ]; then
    tool="/usr/local/sbin/hardening-rollback"
  else
    log_error "Rollback utility not found (rollback.sh or /usr/local/sbin/hardening-rollback)."
    echo "    Download it from ${REPO_RAW_URL}/rollback.sh" >&2
    exit 1
  fi
  local args=()
  [ "$ASSUME_YES" = true ] && args+=(--yes)
  [ -n "$ROLLBACK_FILE" ] && args+=("$ROLLBACK_FILE")
  exec bash "$tool" "${args[@]}"
}

# Installs verify.sh / rollback.sh as system commands (local copy or download)
install_helper_tool() {
  local src_name="$1"
  local dest="$2"
  if [ -f "$SCRIPT_DIR/$src_name" ]; then
    install -m 755 -o root -g root "$SCRIPT_DIR/$src_name" "$dest"
  elif curl -fsSL "${REPO_RAW_URL}/${src_name}" -o "${dest}.tmp" 2>/dev/null; then
    install -m 755 -o root -g root "${dest}.tmp" "$dest"
    rm -f "${dest}.tmp"
  else
    rm -f "${dest}.tmp"
    log_warn "Could not install $dest (download of ${src_name} failed)."
    return 1
  fi
}

# ------------------------------------------------------------------
# Auto-Revert Safety Timer (runs hardening-rollback unless the user confirms)
# ------------------------------------------------------------------
disarm_safety_timer() {
  systemctl stop "${SAFETY_TIMER_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "${SAFETY_TIMER_UNIT}.timer" "${SAFETY_TIMER_UNIT}.service" >/dev/null 2>&1 || true
  SAFETY_TIMER_ARMED=false
}

arm_safety_timer() {
  local minutes="$1"
  disarm_safety_timer
  if ! command -v systemd-run >/dev/null 2>&1 || [ ! -x /usr/local/sbin/hardening-rollback ] || [ -z "$ROLLBACK_SNAPSHOT_PATH" ]; then
    log_warn "Safety timer unavailable (requires systemd-run, /usr/local/sbin/hardening-rollback and a snapshot). Continuing without automatic revert."
    return 0
  fi
  if systemd-run --quiet --unit="$SAFETY_TIMER_UNIT" --on-active="${minutes}min" --timer-property=AccuracySec=1s \
       /usr/local/sbin/hardening-rollback --yes "$ROLLBACK_SNAPSHOT_PATH"; then
    SAFETY_TIMER_ARMED=true
    log_warn "Safety timer armed: automatic rollback at $(date -d "+${minutes} min" +%H:%M) unless confirmed."
  else
    log_warn "Could not arm the safety timer. Continuing without automatic revert."
  fi
}

# ------------------------------------------------------------------
# Parameter Processing (Flags or Positional Arguments)
# ------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  if [[ "$1" == "-"* ]]; then
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -u|--user)          NOVO_USUARIO="$2"; shift 2 ;;
        -k|--key)           CHAVE_SSH="$2"; shift 2 ;;
        -p|--port)          SSH_PORT="$2"; shift 2 ;;
        -t|--timezone)      TIMEZONE="$2"; shift 2 ;;
        -a|--allow-ports)   ALLOW_PORTS="$2"; shift 2 ;;
        --skip-upgrade)     SKIP_UPGRADE=true; shift 1 ;;
        --password-hash)    PASSWORD_HASH="$2"; shift 2 ;;
        --safety-timer)     SAFETY_TIMER=true; shift 1 ;;
        --no-safety-timer)  SAFETY_TIMER=false; shift 1 ;;
        --dry-run)          DRY_RUN=true; shift 1 ;;
        --rollback)
          DO_ROLLBACK=true
          if [ "$#" -gt 1 ] && [[ "$2" != "-"* ]]; then
            ROLLBACK_FILE="$2"
            shift 2
          else
            shift 1
          fi
          ;;
        --tg-token)         TG_BOT_TOKEN="$2"; shift 2 ;;
        --tg-chat)          TG_CHAT_ID="$2"; shift 2 ;;
        -w|--webhook)       WEBHOOK_URL="$2"; shift 2 ;;
        --audit|--lynis)    RUN_AUDIT=true; shift 1 ;;
        --no-verify)        RUN_VERIFY=false; shift 1 ;;
        -y|--yes)           ASSUME_YES=true; shift 1 ;;
        -h|--help)          show_help ;;
        *) log_error "Unknown parameter: $1"; echo "Run '$0 --help' for usage." >&2; exit 1 ;;
      esac
    done
  else
    # Positional
    NOVO_USUARIO="${1:-}"
    CHAVE_SSH="${2:-}"
    SSH_PORT="${3:-52211}"
    TIMEZONE="${4:-America/Sao_Paulo}"
  fi
fi

# Execute rollback immediately if requested
if [ "$DO_ROLLBACK" = true ]; then
  run_rollback_tool
fi

# ------------------------------------------------------------------
# Interactive Mode (if username or SSH key is missing)
# ------------------------------------------------------------------
if [ -z "$NOVO_USUARIO" ] || [ -z "$CHAVE_SSH" ]; then
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}          VPS HARDENING CONFIGURATION WIZARD${C_RESET} ${C_DIM}v${VERSION}${C_RESET}"
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo ""

  DEFAULT_ADMIN_USER="operator"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    DEFAULT_ADMIN_USER="$SUDO_USER"
  fi

  if [ -z "$NOVO_USUARIO" ]; then
    read_input "${C_YELLOW}?${C_RESET} New administrative username [${DEFAULT_ADMIN_USER}]: " NOVO_USUARIO "$DEFAULT_ADMIN_USER"
  fi

  while [ -z "$CHAVE_SSH" ]; do
    echo ""
    log_info "Provide your SSH Public Key (paste raw key, or enter 'gh:username' to import from GitHub):"
    read_input "${C_YELLOW}?${C_RESET} SSH Public Key or GitHub handle: " CHAVE_SSH ""
    if [ -z "$CHAVE_SSH" ]; then
      log_warn "An SSH public key is required to prevent server lockout!"
    fi
  done

  INPUT_PORT=""
  INPUT_TZ=""
  INPUT_PORTS=""
  ENABLE_TG=""
  INPUT_WEBHOOK=""
  INPUT_AUDIT=""

  read_input "${C_YELLOW}?${C_RESET} Custom SSH Port [${SSH_PORT}]: " INPUT_PORT "$SSH_PORT"
  SSH_PORT="$INPUT_PORT"
  echo -e "    ${C_DIM}ℹ️  If your provider has its own firewall (Hetzner, AWS, DigitalOcean...), allow ${SSH_PORT}/tcp there too.${C_RESET}"

  read_input "${C_YELLOW}?${C_RESET} Server Timezone [${TIMEZONE}]: " INPUT_TZ "$TIMEZONE"
  TIMEZONE="$INPUT_TZ"

  if [ -z "$ALLOW_PORTS" ]; then
    read_input "${C_YELLOW}?${C_RESET} Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp) [none]: " INPUT_PORTS ""
    ALLOW_PORTS="$INPUT_PORTS"
  fi

  if [ -z "$TG_BOT_TOKEN" ] && [ -z "$WEBHOOK_URL" ]; then
    echo ""
    log_info "Real-Time SSH Login Alerts (Telegram / Webhook):"
    echo -e "    ${C_DIM}ℹ️  This step is optional. If Telegram or Webhook is not provided, it will NOT be activated.${C_RESET}"
    read_input "${C_YELLOW}?${C_RESET} Configure instant Telegram alerts on SSH login? [y/N]: " ENABLE_TG "N"
    if [[ "$ENABLE_TG" =~ ^[YySs]$ ]]; then
      read_input "    ${C_YELLOW}→${C_RESET} Telegram Bot Token (from @BotFather): " TG_BOT_TOKEN ""
      read_input "    ${C_YELLOW}→${C_RESET} Telegram Chat ID (from @userinfobot): " TG_CHAT_ID ""
    else
      read_input "${C_YELLOW}?${C_RESET} Alternative Webhook URL (Discord / Slack / Custom) [skip/Enter]: " INPUT_WEBHOOK ""
      WEBHOOK_URL="$INPUT_WEBHOOK"
    fi
    if [ -z "$TG_BOT_TOKEN" ] && [ -z "$WEBHOOK_URL" ]; then
      log_info "SSH Alerts: No notification channel provided. Step will remain inactive."
    fi
  fi

  if [ "$ASSUME_YES" = false ] && [ "$RUN_AUDIT" = false ]; then
    read_input "${C_YELLOW}?${C_RESET} Run Lynis security audit scan after hardening? [y/N]: " INPUT_AUDIT "N"
    if [[ "$INPUT_AUDIT" =~ ^[YySs]$ ]]; then
      RUN_AUDIT=true
    fi
  fi
fi

# ------------------------------------------------------------------
# Data Validation
# ------------------------------------------------------------------
# 1. Username validation
if ! [[ "$NOVO_USUARIO" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  log_error "Invalid username: '$NOVO_USUARIO'. Use lowercase letters, digits, and underscores."
  exit 1
fi

if [ "$NOVO_USUARIO" = "root" ]; then
  log_error "The new username cannot be 'root'. Please select a non-root name (e.g., operator)."
  exit 1
fi

# 2. SSH key resolution & validation
if [[ "$CHAVE_SSH" =~ ^gh:([A-Za-z0-9_-]+)$ ]]; then
  gh_user="${BASH_REMATCH[1]}"
  log_info "Fetching public SSH key(s) from GitHub for user '${gh_user}'..."
  fetched_keys=$(curl -fsSL "https://github.com/${gh_user}.keys" 2>/dev/null || true)
  if [ -z "$fetched_keys" ]; then
    log_error "Could not retrieve any public SSH keys from https://github.com/${gh_user}.keys"
    echo "    Make sure the GitHub username exists and has public keys added at https://github.com/settings/keys"
    exit 1
  fi
  CHAVE_SSH="$fetched_keys"
  log_success "Successfully fetched $(echo "$CHAVE_SSH" | grep -cE '^(ssh-|ecdsa-|sk-)') public key(s) from GitHub (${gh_user})."
elif [[ "$CHAVE_SSH" =~ ^https?:// ]]; then
  log_info "Fetching public SSH key from URL: ${CHAVE_SSH}..."
  fetched_keys=$(curl -fsSL "$CHAVE_SSH" 2>/dev/null || true)
  if [ -z "$fetched_keys" ]; then
    log_error "Could not retrieve public SSH key from URL: ${CHAVE_SSH}"
    exit 1
  fi
  CHAVE_SSH="$fetched_keys"
fi

valid_key_found=false
while IFS= read -r key_line || [ -n "$key_line" ]; do
  k_clean="$(echo "$key_line" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$k_clean" ] && continue
  if echo "$k_clean" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp[0-9]+@openssh.com) [A-Za-z0-9+/=]+'; then
    valid_key_found=true
  fi
done <<< "$CHAVE_SSH"

if [ "$valid_key_found" = false ]; then
  log_error "The SSH public key does not appear to be in a valid OpenSSH format."
  echo "    Expected format: ssh-ed25519 AAAAC3NzaC1... comment (or gh:username)"
  exit 1
fi

# 3. Port validation
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
  log_error "Invalid port: '$SSH_PORT'. Must be a number between 1024 and 65535."
  exit 1
fi

# 4. Password hash validation (crypt format: $6$..., $y$..., $5$..., $2b$...)
if [ -n "$PASSWORD_HASH" ] && ! [[ "$PASSWORD_HASH" =~ ^\$[0-9a-z]+\$[./0-9A-Za-z$=,]+$ ]]; then
  log_error "Invalid --password-hash: expected a crypt hash such as '\$6\$...' (never a plain-text password)."
  echo "    Generate one with: openssl passwd -6" >&2
  exit 1
fi

# 5. The admin account needs a password for sudo. Without a TTY or with -y, it must come from --password-hash.
ADMIN_NEEDS_PASSWORD=false
if ! id "$NOVO_USUARIO" &>/dev/null || [[ "$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo L)" =~ ^(L|NP)$ ]]; then
  ADMIN_NEEDS_PASSWORD=true
fi
if [ "$ADMIN_NEEDS_PASSWORD" = true ] && [ -z "$PASSWORD_HASH" ]; then
  if [ "$ASSUME_YES" = true ] || ! { : < /dev/tty; } 2>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
      log_warn "User '${NOVO_USUARIO}' has no password: a real non-interactive run requires --password-hash."
    else
      log_error "User '${NOVO_USUARIO}' has no password and none can be asked interactively (-y or no terminal)."
      echo "    Pass a crypt hash for the sudo password: --password-hash \"\$(openssl passwd -6)\"" >&2
      echo "    No changes were made to the system." >&2
      exit 1
    fi
  fi
fi

# 6. Safety timer default: on for interactive runs, off with -y (nobody is there to confirm)
if [ "$SAFETY_TIMER" = auto ]; then
  if [ "$ASSUME_YES" = true ]; then
    SAFETY_TIMER=false
  else
    SAFETY_TIMER=true
  fi
fi

# ------------------------------------------------------------------
# Plan Confirmation
# ------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}--- Hardening Parameters (vps_hardening v${VERSION}) ---${C_RESET}"
echo -e "  New User:          ${C_GREEN}${NOVO_USUARIO}${C_RESET}"
echo -e "  SSH Public Key:    ${C_GREEN}${CHAVE_SSH:0:40}...${C_RESET}"
echo -e "  New SSH Port:      ${C_GREEN}${SSH_PORT}${C_RESET}"
echo -e "  Allowed Ports:     ${C_GREEN}${ALLOW_PORTS:-None (SSH only)}${C_RESET}"
echo -e "  Timezone:          ${C_GREEN}${TIMEZONE}${C_RESET}"
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  echo -e "  Telegram Alert:    ${C_GREEN}Active (Chat ID: ${TG_CHAT_ID})${C_RESET}"
elif [ -n "$WEBHOOK_URL" ]; then
  echo -e "  SSH Login Webhook: ${C_GREEN}${WEBHOOK_URL:0:35}...${C_RESET}"
else
  echo -e "  SSH Login Alert:   ${C_YELLOW}Not Configured (Optional — active only if Telegram or Webhook is provided)${C_RESET}"
fi
echo -e "  Lynis Audit Scan:  ${C_GREEN}${RUN_AUDIT}${C_RESET}"
if [ "$SAFETY_TIMER" = true ]; then
  echo -e "  Safety Timer:      ${C_GREEN}auto-revert in ${SAFETY_TIMER_MINUTES} min unless you confirm the new SSH login${C_RESET}"
else
  echo -e "  Safety Timer:      ${C_YELLOW}disabled${C_RESET}"
fi
if [ "$DRY_RUN" = true ]; then
  echo -e "  Execution Mode:    ${C_YELLOW}${C_BOLD}DRY-RUN (SIMULATION ONLY)${C_RESET}"
fi
echo -e "${C_BOLD}----------------------------${C_RESET}"
echo ""
log_warn "Make sure port ${C_BOLD}${SSH_PORT}/tcp${C_RESET} is also allowed in your provider's firewall (Hetzner Cloud Firewall, AWS Security Group, DigitalOcean Cloud Firewall, etc.)."

echo ""

if [ "$ASSUME_YES" = false ]; then
  CONFIRM=""
  read_input "${C_YELLOW}?${C_RESET} Do you want to proceed with applying security hardening? [Y/n]: " CONFIRM "Y"
  if [[ ! "$CONFIRM" =~ ^[YySs]$ ]] && [ -n "$CONFIRM" ]; then
    log_warn "Operation cancelled by user."
    exit 0
  fi
fi

run_dry_run_simulation() {
  local p p_clean
  echo -e "${C_YELLOW}${C_BOLD}==============================================================================${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}   ⚠️  SIMULATION MODE (DRY-RUN) ACTIVE — NO SYSTEM CHANGES WILL BE MADE       ${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}==============================================================================${C_RESET}"
  echo ""
  echo -e "${C_CYAN}${C_BOLD}[*] Running full pre-flight simulation of all 11 hardening phases...${C_RESET}"
  echo ""

  echo -e "${C_BOLD}Pre-flight: Rollback Snapshot & Helper Commands${C_RESET}"
  if [ -e "$BACKUP_DIR/latest.tar.gz" ]; then
    echo -e "  [DRY-RUN] Original snapshot already exists ($(readlink -f "$BACKUP_DIR/latest.tar.gz")) — would keep it"
  else
    echo -e "  [DRY-RUN] Would create root-only snapshot ${BACKUP_DIR}/hardening_backup_<timestamp>.tar.gz"
    echo -e "            plus .created (files this run creates) and .state (services, UFW, sysctl, accounts)"
  fi
  echo -e "  [DRY-RUN] Would install /usr/local/bin/verify-hardening and /usr/local/sbin/hardening-rollback"
  echo ""

  echo -e "${C_BOLD}Phase 1: Base System & Time Synchronization${C_RESET}"
  echo -e "  [DRY-RUN] Would update package lists: apt-get update"
  if [ "$SKIP_UPGRADE" = true ]; then
    echo -e "  [DRY-RUN] Package upgrade skipped (--skip-upgrade)"
  else
    echo -e "  [DRY-RUN] Would upgrade installed packages: apt-get upgrade -y"
  fi
  echo -e "  [DRY-RUN] Would ensure baseline tools: apt-get install -y sudo curl tmux"
  echo -e "  [DRY-RUN] Would configure system timezone to '${TIMEZONE}' via timedatectl"
  echo -e "  [DRY-RUN] Would enable network time synchronization (NTP)"
  echo ""

  echo -e "${C_BOLD}Phase 2: Administrative User & Cloud Account Neutralization${C_RESET}"
  echo -e "  [DRY-RUN] Would verify or create user '${NOVO_USUARIO}' with bash shell"
  echo -e "  [DRY-RUN] Would add '${NOVO_USUARIO}' to the sudo group (usermod -aG sudo ${NOVO_USUARIO})"
  if [ -n "$PASSWORD_HASH" ]; then
    echo -e "  [DRY-RUN] Would set the sudo password from --password-hash if the account has none"
  else
    echo -e "  [DRY-RUN] Would prompt for a sudo password if the account has none"
  fi
  echo -e "  [DRY-RUN] Would neutralize default accounts (${DEFAULT_CLOUD_ACCOUNTS[*]}):"
  echo -e "            - Lock passwords (passwd -l)"
  echo -e "            - Set shell to /usr/sbin/nologin"
  echo -e "            - Rename .ssh/authorized_keys to authorized_keys.disabled"
  echo ""

  echo -e "${C_BOLD}Phase 3: OpenSSH Hardening${C_RESET}"
  echo -e "  [DRY-RUN] Would install public key(s) in ~${NOVO_USUARIO}/.ssh/authorized_keys (dir 700, file 600)"
  echo -e "  [DRY-RUN] Would back up /etc/ssh/sshd_config to /etc/ssh/sshd_config.bak (first run only)"
  echo -e "  [DRY-RUN] Would comment out conflicting directives in sshd_config and sshd_config.d/*.conf (*.bak backups)"
  echo -e "  [DRY-RUN] Would write /etc/ssh/sshd_config.d/00-hardening.conf:"
  echo -e "            - Port ${SSH_PORT}"
  echo -e "            - PermitRootLogin no"
  echo -e "            - PasswordAuthentication no / PermitEmptyPasswords no / KbdInteractiveAuthentication no"
  echo -e "            - PubkeyAuthentication yes"
  echo -e "            - X11Forwarding no"
  echo -e "            - MaxAuthTries 3 / LoginGraceTime 20"
  echo -e "            - AllowUsers ${NOVO_USUARIO}"
  echo -e "            - ClientAliveInterval 300 / ClientAliveCountMax 2"
  echo -e "  [DRY-RUN] Would validate syntax with 'sshd -t' (aborts on error)"
  echo -e "  [DRY-RUN] If UFW is already active, would open ${SSH_PORT}/tcp before restarting SSH"
  if [ "$SAFETY_TIMER" = true ]; then
    echo -e "  [DRY-RUN] Would arm the auto-revert safety timer (systemd-run ${SAFETY_TIMER_UNIT})"
  fi
  echo -e "  [DRY-RUN] Would disable ssh.socket (socket activation) and restart ssh.service"
  echo ""

  echo -e "${C_BOLD}Phase 4: Stateful Firewall (UFW)${C_RESET}"
  echo -e "  [DRY-RUN] Would install ufw and enable IPv6 rules (/etc/default/ufw)"
  echo -e "  [DRY-RUN] Would set default policies: deny incoming, allow outgoing"
  echo -e "  [DRY-RUN] Would rate-limit SSH: ufw limit ${SSH_PORT}/tcp"
  if [ -n "$ALLOW_PORTS" ]; then
    IFS=',' read -ra ADDR <<< "$ALLOW_PORTS"
    for p in "${ADDR[@]}"; do
      p_clean=$(echo "$p" | tr -d '[:space:]')
      [ -n "$p_clean" ] && echo -e "  [DRY-RUN] Would allow additional port: ufw allow ${p_clean}"
    done
  fi
  echo -e "  [DRY-RUN] Would enable firewall: ufw --force enable"
  echo ""

  echo -e "${C_BOLD}Phase 5: Intrusion Prevention & Brute-Force Defense (Fail2ban)${C_RESET}"
  echo -e "  [DRY-RUN] Would install fail2ban"
  echo -e "  [DRY-RUN] Would write /etc/fail2ban/jail.local:"
  echo -e "            - [DEFAULT] backend: systemd, ignoreip: loopback + RFC1918, bantime 1h, findtime 10m, maxretry 4"
  echo -e "            - [DEFAULT] progressive bans: bantime.increment, factor 2, max 7 days"
  echo -e "            - [sshd] port: ${SSH_PORT}, maxretry: 3, findtime: 5m, bantime: 2h"
  echo -e "  [DRY-RUN] Would enable and restart the fail2ban service"
  echo ""

  echo -e "${C_BOLD}Phase 6: Kernel Hardening (sysctl) & Network Optimization${C_RESET}"
  echo -e "  [DRY-RUN] Detected virtualization: ${VIRT_ENV} ($([ "$IS_CONTAINER" = true ] && echo "container profile" || echo "full profile"))"
  echo -e "  [DRY-RUN] Would write /etc/sysctl.d/99-hardening.conf:"
  echo -e "            - Source routing and ICMP redirects disabled"
  echo -e "            - Reverse-path filtering (rp_filter = 1) and martian logging"
  echo -e "            - TCP SYN cookies, broadcast/bogus ICMP ignored"
  echo -e "            - fs.suid_dumpable = 0"
  if [ "$IS_CONTAINER" = false ]; then
    echo -e "            - ASLR (randomize_va_space = 2), kptr_restrict = 2, dmesg_restrict = 1"
    echo -e "            - TCP BBR congestion control & fair queuing (FQ), tcp_bbr in /etc/modules-load.d/bbr.conf"
  else
    echo -e "            - TCP BBR & FQ only if the host kernel offers bbr"
  fi
  echo -e "  [DRY-RUN] Would load kernel parameters: sysctl --system"
  echo ""

  echo -e "${C_BOLD}Phase 7: Automatic Security Updates (Unattended-Upgrades)${C_RESET}"
  echo -e "  [DRY-RUN] Would install unattended-upgrades and apt-listchanges"
  echo -e "  [DRY-RUN] Would write /etc/apt/apt.conf.d/20auto-upgrades (daily lists update + unattended upgrade)"
  echo -e "  [DRY-RUN] Would enable the unattended-upgrades service"
  echo ""

  echo -e "${C_BOLD}Phase 8: Filesystem & Memory Protection (CIS Benchmark)${C_RESET}"
  echo -e "  [DRY-RUN] Would set /dev/shm to nodev,nosuid,noexec in /etc/fstab and remount it"
  echo -e "  [DRY-RUN] Would write /etc/security/limits.d/10-hardening-coredump.conf (* hard/soft core 0)"
  echo -e "  [DRY-RUN] Would write /etc/systemd/coredump.conf.d/disable.conf (Storage=none, ProcessSizeMax=0)"
  echo ""

  echo -e "${C_BOLD}Phase 9: Legacy Network Protocols Blacklist (Modprobe)${C_RESET}"
  echo -e "  [DRY-RUN] Would write /etc/modprobe.d/hardening.conf:"
  echo -e "            - install dccp /bin/true"
  echo -e "            - install sctp /bin/true"
  echo -e "            - install rds /bin/true"
  echo -e "            - install tipc /bin/true"
  echo -e "            - install firewire-core /bin/true"
  echo ""

  echo -e "${C_BOLD}Phase 10: System Security Auditing (Auditd & Lynis)${C_RESET}"
  echo -e "  [DRY-RUN] Would install, enable and start auditd"
  if [ "$RUN_AUDIT" = true ]; then
    echo -e "  [DRY-RUN] Would install Lynis and run: lynis audit system --quick (report: /var/log/lynis-hardening-report.txt)"
  else
    echo -e "  [DRY-RUN] Lynis audit scan skipped (use --audit to enable)"
  fi
  echo ""

  if { [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; } || [ -n "$WEBHOOK_URL" ]; then
    echo -e "${C_BOLD}Phase 11: Real-Time SSH Login Alerts (PAM)${C_RESET}"
    echo -e "  [DRY-RUN] Would store credentials in /etc/vps-hardening/alert.conf (root only, mode 600)"
    echo -e "  [DRY-RUN] Would install dispatcher /usr/local/bin/ssh-login-alert.sh (root only, mode 700)"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      echo -e "  [DRY-RUN] Notification provider: Telegram (Chat ID: ${TG_CHAT_ID})"
    else
      echo -e "  [DRY-RUN] Notification provider: Webhook (${WEBHOOK_URL:0:30}...)"
    fi
    echo -e "  [DRY-RUN] Would append a pam_exec session hook to /etc/pam.d/sshd (backup: /etc/pam.d/sshd.bak)"
  else
    echo -e "${C_BOLD}Phase 11: Real-Time SSH Login Alerts (Optional)${C_RESET}"
    echo -e "  [DRY-RUN] Not configured — provide --tg-token/--tg-chat or --webhook to enable it."
  fi
  echo ""

  echo -e "${C_BOLD}Post-run${C_RESET}"
  if [ "$RUN_VERIFY" = true ]; then
    echo -e "  [DRY-RUN] Would run the verification suite: verify-hardening --port ${SSH_PORT} --user ${NOVO_USUARIO}"
  fi
  if [ "$SAFETY_TIMER" = true ]; then
    echo -e "  [DRY-RUN] Would reset the safety timer to ${SAFETY_TIMER_MINUTES} min and wait for you to type CONFIRM"
  fi
  echo ""

  echo -e "${C_BOLD}==============================================================================${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}                   ✔ DRY-RUN SIMULATION COMPLETED!                           ${C_RESET}"
  echo -e "${C_BOLD}==============================================================================${C_RESET}"
  echo ""
  echo -e "  ${C_GREEN}Zero changes were made to your system.${C_RESET}"
  echo -e "  To execute hardening for real, re-run without the --dry-run flag."
  echo ""
  echo -e "${C_BOLD}==============================================================================${C_RESET}"
  exit 0
}

echo ""
if [ "$DRY_RUN" = true ]; then
  run_dry_run_simulation
else
  create_rollback_snapshot
  log_info "Installing helper commands (verify-hardening, hardening-rollback)..."
  install_helper_tool verify.sh /usr/local/bin/verify-hardening || true
  install_helper_tool rollback.sh /usr/local/sbin/hardening-rollback || true
  echo ""
fi

log_info "Starting hardening process..."

# ==================================================================
# PHASE 1 — Base System & Time Synchronization
# ==================================================================
echo ""
log_step "Phase 1 — Base System & Time Synchronization"
log_info "Objective: Update package repositories, install essential utilities (sudo, curl, tmux), and synchronize clock via NTP."

if [ "$SKIP_UPGRADE" = true ]; then
  log_step "1.1 Updating package lists (package upgrade skipped via --skip-upgrade)..."
  apt-get update -qq
else
  log_step "1.1 Updating package lists and upgrading installed packages..."
  apt-get update -qq
  apt-get upgrade -y -qq
  log_success "Installed packages upgraded."
fi

if command -v sudo >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
  log_success "1.2 Baseline tools (sudo, curl, tmux) are already installed. Skipping..."
else
  log_step "1.2 Installing baseline packages (sudo, curl, tmux)..."
  apt-get install -y -qq sudo curl tmux
fi

CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
NTP_SYNC="$(timedatectl status 2>/dev/null | grep -E 'NTP service: active|Network time on: yes|System clock synchronized: yes' || true)"

if [ -n "$NTP_SYNC" ] && { [ "$CURRENT_TZ" = "$TIMEZONE" ] || [ -z "$TIMEZONE" ]; }; then
  log_success "1.3 Timezone ($TIMEZONE) and NTP synchronization are already configured at standard. Skipping..."
else
  log_step "1.3 Configuring Timezone ($TIMEZONE) and NTP synchronization..."
  if timedatectl list-timezones | grep -qx "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE"
  else
    log_warn "Timezone '$TIMEZONE' not found on system. Keeping current timezone."
  fi
  timedatectl set-ntp true 2>/dev/null || true
  log_success "System clock synchronized."
fi

# ==================================================================
# PHASE 2 — User Accounts
# ==================================================================
echo ""
log_step "Phase 2 — Administrative User & Cloud Account Neutralization"
log_info "Objective: Provision user '${NOVO_USUARIO}' with sudo privileges and lock vulnerable default cloud accounts (ubuntu, debian, admin, etc.)."

PHASE2_ALREADY_CONFIGURED=false
if id "$NOVO_USUARIO" &>/dev/null && id -nG "$NOVO_USUARIO" 2>/dev/null | grep -qw "sudo"; then
  PASSWD_CHECK="$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")"
  if [[ ! "$PASSWD_CHECK" =~ ^(L|NP)$ ]]; then
    DEFAULTS_SECURE=true
    for u in "${DEFAULT_CLOUD_ACCOUNTS[@]}"; do
      if id "$u" &>/dev/null && [ "$u" != "$NOVO_USUARIO" ]; then
        u_shell="$(getent passwd "$u" | cut -d: -f7)"
        u_pwd="$(passwd -S "$u" 2>/dev/null | awk '{print $2}' || echo "")"
        if [ "$u_shell" != "/usr/sbin/nologin" ] && [ "$u_shell" != "/bin/false" ] && [ "$u_pwd" != "L" ]; then
          DEFAULTS_SECURE=false
          break
        fi
        if [ -f "/home/$u/.ssh/authorized_keys" ]; then
          DEFAULTS_SECURE=false
          break
        fi
      fi
    done
    if [ "$DEFAULTS_SECURE" = true ]; then
      PHASE2_ALREADY_CONFIGURED=true
    fi
  fi
fi

if [ "$PHASE2_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 2: User '${NOVO_USUARIO}' and default cloud accounts are already configured at standard. Skipping..."
else
  log_step "2.1 Creating or configuring user '${NOVO_USUARIO}'..."
  if id "$NOVO_USUARIO" &>/dev/null; then
    log_info "User '${NOVO_USUARIO}' already exists, ensuring sudo group membership."
  else
    if getent group "$NOVO_USUARIO" >/dev/null 2>&1; then
      useradd -m -g "$NOVO_USUARIO" -s /bin/bash "$NOVO_USUARIO"
    else
      useradd -m -U -s /bin/bash "$NOVO_USUARIO" 2>/dev/null || useradd -m -s /bin/bash "$NOVO_USUARIO"
    fi
    log_success "User '${NOVO_USUARIO}' created successfully."
  fi
  if ! getent group sudo >/dev/null 2>&1; then
    groupadd sudo
  fi
  usermod -aG sudo "$NOVO_USUARIO"

  # Set password if account is locked or has no password (required for sudo)
  PASSWD_STATUS="$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")"
  if [[ "$PASSWD_STATUS" =~ ^(L|NP)$ ]] && [ -n "$PASSWORD_HASH" ]; then
    usermod -p "$PASSWORD_HASH" "$NOVO_USUARIO"
    log_success "Sudo password for '${NOVO_USUARIO}' set from --password-hash."
  elif [[ "$PASSWD_STATUS" =~ ^(L|NP)$ ]]; then
    echo ""
    log_warn "ATTENTION: Set the password for '${NOVO_USUARIO}' (required for sudo):"
    if { : < /dev/tty; } 2>/dev/null; then
      passwd "$NOVO_USUARIO" < /dev/tty
    else
      passwd "$NOVO_USUARIO"
    fi
    echo ""
  fi

  log_step "2.2 Neutralizing cloud provider default administrative accounts..."
  for u in "${DEFAULT_CLOUD_ACCOUNTS[@]}"; do
    if id "$u" &>/dev/null && [ "$u" != "$NOVO_USUARIO" ]; then
      passwd -l "$u" >/dev/null 2>&1 || true
      usermod -s /usr/sbin/nologin "$u" 2>/dev/null || true
      if [ -f "/home/$u/.ssh/authorized_keys" ]; then
        mv "/home/$u/.ssh/authorized_keys" "/home/$u/.ssh/authorized_keys.disabled" 2>/dev/null || true
      fi
      log_info "Default account '$u' neutralized (authorized_keys moved to .disabled)."
    fi
  done
  log_success "User account hardening completed."
fi

# ==================================================================
# PHASE 3 — SSH Hardening
# ==================================================================
echo ""
log_step "Phase 3 — Cryptographic OpenSSH Hardening"
log_info "Objective: Migrate to port $SSH_PORT, disable root/password logins, and enforce SSH key authentication only."

USER_HOME="$(getent passwd "$NOVO_USUARIO" 2>/dev/null | cut -d: -f6 || echo "/home/$NOVO_USUARIO")"
PHASE3_ALREADY_CONFIGURED=false

if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ] && [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
  if grep -qE "^\s*Port\s+$SSH_PORT\b" /etc/ssh/sshd_config.d/00-hardening.conf && \
     grep -qE "^\s*PermitRootLogin\s+no\b" /etc/ssh/sshd_config.d/00-hardening.conf && \
     grep -qE "^\s*PasswordAuthentication\s+no\b" /etc/ssh/sshd_config.d/00-hardening.conf && \
     grep -qE "^\s*AllowUsers\s+.*$NOVO_USUARIO" /etc/ssh/sshd_config.d/00-hardening.conf; then
    if ss -tlnp 2>/dev/null | grep -E "ssh" | grep -qE ":$SSH_PORT\b"; then
      ALL_KEYS_PRESENT=true
      while IFS= read -r key_line || [ -n "$key_line" ]; do
        k_clean="$(echo "$key_line" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$k_clean" ] && continue
        if ! grep -qxF "$k_clean" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
          ALL_KEYS_PRESENT=false
          break
        fi
      done <<< "$CHAVE_SSH"
      if [ "$ALL_KEYS_PRESENT" = true ]; then
        PHASE3_ALREADY_CONFIGURED=true
      fi
    fi
  fi
fi

if [ "$PHASE3_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 3: OpenSSH is already configured at standard (port $SSH_PORT, key-only authentication). Skipping..."
else
  log_step "3.1 Installing authorized SSH key for '${NOVO_USUARIO}'..."
  mkdir -p "$USER_HOME/.ssh"
  while IFS= read -r key_line || [ -n "$key_line" ]; do
    k_clean="$(echo "$key_line" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$k_clean" ] && continue
    if ! grep -qxF "$k_clean" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
      echo "$k_clean" >> "$USER_HOME/.ssh/authorized_keys"
    fi
  done <<< "$CHAVE_SSH"
  chmod 700 "$USER_HOME/.ssh"
  chmod 600 "$USER_HOME/.ssh/authorized_keys"
  chown -R "$NOVO_USUARIO":"$NOVO_USUARIO" "$USER_HOME/.ssh"
  log_success "Authorized SSH key(s) installed in $USER_HOME/.ssh/authorized_keys."

  log_step "3.2 Sanitizing /etc/ssh/sshd_config and neutralizing conflicting overrides..."
  if [ -f /etc/ssh/sshd_config ]; then
    if [ ! -f /etc/ssh/sshd_config.bak ]; then
      cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
      log_info "Backup of /etc/ssh/sshd_config created at /etc/ssh/sshd_config.bak"
    fi

    sed -i -E 's/^\s*(Port|PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords|KbdInteractiveAuthentication|PubkeyAuthentication|X11Forwarding|MaxAuthTries|LoginGraceTime|AllowUsers)\b/#&/' /etc/ssh/sshd_config

    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
      sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
      log_info "Added 'Include /etc/ssh/sshd_config.d/*.conf' to the top of /etc/ssh/sshd_config"
    fi
  fi

  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -e "$f" ] || continue
      [ "$(basename "$f")" = "00-hardening.conf" ] && continue
      if grep -qE '^\s*(PasswordAuthentication|PermitRootLogin|Port|PermitEmptyPasswords|KbdInteractiveAuthentication|PubkeyAuthentication|X11Forwarding|MaxAuthTries|LoginGraceTime|AllowUsers)\b' "$f"; then
        [ -f "${f}.bak" ] || cp "$f" "${f}.bak"
        sed -i -E 's/^\s*(PasswordAuthentication|PermitRootLogin|Port|PermitEmptyPasswords|KbdInteractiveAuthentication|PubkeyAuthentication|X11Forwarding|MaxAuthTries|LoginGraceTime|AllowUsers)\b/#&/' "$f"
        log_info "Neutralized override file: $f (backup at ${f}.bak)"
      fi
    done
  fi

  log_step "3.3 Applying hardened configuration to /etc/ssh/sshd_config.d/00-hardening.conf..."
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Generated automatically by VPS Hardening Script
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
AllowUsers $NOVO_USUARIO
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

  log_step "3.4 Validating OpenSSH configuration syntax..."
  # With socket activation (Ubuntu 22.10+) /run/sshd only exists while ssh.service runs
  install -d -m 755 /run/sshd
  if ! sshd -t; then
    log_error "SSH configuration syntax check failed! Aborting service reload to prevent lockout."
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    exit 1
  fi
  log_success "SSH configuration syntax is valid."

  log_step "3.5 Resolving socket activation (Ubuntu 22.10+) and restarting SSH..."
  # If UFW is already active, open the new port before sshd moves to it
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw limit "$SSH_PORT"/tcp comment 'SSH Hardened Port' >/dev/null
    log_info "UFW already active: opened ${SSH_PORT}/tcp before restarting SSH."
  fi
  if [ "$SAFETY_TIMER" = true ]; then
    # Generous window covering the remaining phases; reset to SAFETY_TIMER_MINUTES at the end
    arm_safety_timer 60
  fi
  systemctl disable --now ssh.socket 2>/dev/null || true
  systemctl enable ssh.service >/dev/null 2>&1 || true
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service

  sleep 2
  if ss -tlnp | grep -qE ":$SSH_PORT\b"; then
    log_success "SSH service is active and listening on port $SSH_PORT."
  else
    log_warn "Warning: sshd may not be listening on port $SSH_PORT yet. Verify with 'ss -tunap | grep sshd'."
  fi
fi

# ==================================================================
# PHASE 4 — Firewall (UFW)
# ==================================================================
echo ""
log_step "Phase 4 — Stateful Firewall (UFW)"
log_info "Objective: Enable firewall with default-deny inbound policy and rate-limiting on port $SSH_PORT."

PHASE4_ALREADY_CONFIGURED=false
if command -v ufw >/dev/null 2>&1; then
  UFW_STAT="$(ufw status 2>/dev/null || true)"
  if echo "$UFW_STAT" | grep -q "Status: active"; then
    if ufw status verbose 2>/dev/null | grep -qi "deny (incoming)"; then
      if echo "$UFW_STAT" | grep -qE "${SSH_PORT}(/tcp)?\s+(LIMIT|ALLOW)"; then
        ALL_CUSTOM_PORTS_OK=true
        if [ -n "$ALLOW_PORTS" ]; then
          IFS=',' read -ra ADDR <<< "$ALLOW_PORTS"
          for port_entry in "${ADDR[@]}"; do
            port_entry="$(echo "$port_entry" | tr -d ' ')"
            [ -n "$port_entry" ] || continue
            if ! echo "$UFW_STAT" | grep -q "$port_entry"; then
              ALL_CUSTOM_PORTS_OK=false
              break
            fi
          done
        fi
        if [ "$ALL_CUSTOM_PORTS_OK" = true ]; then
          PHASE4_ALREADY_CONFIGURED=true
        fi
      fi
    fi
  fi
fi

if [ "$PHASE4_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 4: UFW Firewall is already active and configured at standard with port $SSH_PORT. Skipping..."
else
  log_step "4. Configuring UFW Firewall..."
  apt-get install -y -qq ufw

  if [ -f /etc/default/ufw ]; then
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw limit "$SSH_PORT"/tcp comment 'SSH Hardened Port' >/dev/null

  if [ -n "$ALLOW_PORTS" ]; then
    IFS=',' read -ra ADDR <<< "$ALLOW_PORTS"
    for port_entry in "${ADDR[@]}"; do
      port_entry="$(echo "$port_entry" | tr -d ' ')"
      [ -n "$port_entry" ] || continue
      ufw allow "$port_entry" comment 'Custom allowed port' >/dev/null
      log_info "Allowed incoming traffic on custom port: $port_entry"
    done
  fi

  ufw --force enable >/dev/null
  log_success "UFW active with restrictive default-deny policy and rate-limiting on port $SSH_PORT."
fi

# ==================================================================
# PHASE 5 — Fail2ban & Brute Force Protection
# ==================================================================
echo ""
log_step "Phase 5 — Intrusion Prevention & Brute-Force Defense (Fail2ban)"
log_info "Objective: Protect against repeated brute-force attacks with progressive ban escalation on port $SSH_PORT."

PHASE5_ALREADY_CONFIGURED=false
if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
  if [ -f /etc/fail2ban/jail.local ] && grep -qE "^\s*port\s*=\s*$SSH_PORT\b" /etc/fail2ban/jail.local; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
      PHASE5_ALREADY_CONFIGURED=true
    fi
  fi
fi

if [ "$PHASE5_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 5: Fail2ban is already active and configured at standard monitoring port $SSH_PORT. Skipping..."
else
  log_step "5. Installing and configuring fail2ban..."
  apt-get install -y -qq fail2ban

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Ignore localhost, IPv6 loopback, Docker ranges, and RFC1918 private subnets
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
bantime = 3600
findtime = 600
maxretry = 4
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
findtime = 300
bantime = 7200
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 2

  if fail2ban-client status sshd >/dev/null 2>&1; then
    log_success "Fail2ban active with jail [sshd] monitoring port $SSH_PORT."
  else
    log_warn "Fail2ban started, but jail [sshd] may take a few moments to respond."
  fi
fi

# ==================================================================
# PHASE 6 — Kernel Hardening (sysctl)
# ==================================================================
echo ""
log_step "Phase 6 — Kernel Hardening (sysctl) & Network Optimization"
log_info "Objective: Apply anti-spoofing network parameters, SYN flood protection, ASLR, pointer restrictions, and TCP BBR."

detect_virtualization

PHASE6_ALREADY_CONFIGURED=false
if [ -f /etc/sysctl.d/99-hardening.conf ]; then
  if [ "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || true)" = "1" ] && \
     [ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || true)" = "1" ] && \
     [ "$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null || true)" = "0" ] && \
     [ "$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null || true)" = "0" ] && \
     [ "$(sysctl -n fs.suid_dumpable 2>/dev/null || true)" = "0" ]; then
    if [ "$IS_CONTAINER" = true ]; then
      PHASE6_ALREADY_CONFIGURED=true
    else
      if [ "$(sysctl -n kernel.randomize_va_space 2>/dev/null || true)" = "2" ] && \
         [ "$(sysctl -n kernel.kptr_restrict 2>/dev/null || true)" = "2" ] && \
         [ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null || true)" = "1" ]; then
        PHASE6_ALREADY_CONFIGURED=true
      fi
    fi
  fi
fi

if [ "$PHASE6_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 6: Kernel parameters (sysctl) and network optimizations are already configured at standard ($VIRT_ENV). Skipping..."
else
  log_step "6. Detecting virtualization environment and applying kernel parameters (sysctl)..."

  if [ "$IS_CONTAINER" = true ]; then
    log_info "Container virtualization detected ($VIRT_ENV). Applying container-compatible network security profile (bypassing host-managed ASLR/kptr)..."
    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# /etc/sysctl.d/99-hardening.conf (Container Profile: OpenVZ / LXC / Docker)
# Hardened network parameters supported in containerized environments

# Anti IP spoofing / source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP redirects (prevents MITM attacks via fraudulent routes)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Reverse path filtering (anti spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log packets with suspicious/martian addresses
net.ipv4.conf.all.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Ignore broadcast ping requests (anti smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Disable core dumps for setuid binaries
fs.suid_dumpable = 0
EOF
  else
    log_info "Standard/KVM/Bare-metal environment detected ($VIRT_ENV). Applying full kernel security profile..."
    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Anti IP spoofing / source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP redirects (prevents MITM attacks via fraudulent routes)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Reverse path filtering (anti spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log packets with suspicious/martian addresses
net.ipv4.conf.all.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Ignore broadcast ping requests (anti smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Maximum ASLR (mitigates memory buffer overflow exploits)
kernel.randomize_va_space = 2

# Restrict kernel pointer exposure in /proc
kernel.kptr_restrict = 2

# Restrict dmesg kernel logs to privileged root users
kernel.dmesg_restrict = 1

# Disable core dumps for setuid binaries
fs.suid_dumpable = 0

# TCP BBR Congestion Control & Fair Queuing (latency & throughput optimization)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    modprobe tcp_bbr 2>/dev/null || true
    if [ -d /etc/modules-load.d ]; then
      echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    fi
  fi

  if [ "$IS_CONTAINER" = true ]; then
    modprobe tcp_bbr 2>/dev/null || true
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      cat >> /etc/sysctl.d/99-hardening.conf <<'EOF'

# TCP BBR Congestion Control & Fair Queuing (latency & throughput optimization)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi
  fi

  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1 || true
  log_success "Kernel hardening parameters applied successfully ($VIRT_ENV profile)."
fi

# ==================================================================
# PHASE 7 — Automatic Security Updates
# ==================================================================
echo ""
log_step "Phase 7 — Automatic Security Updates (Unattended-Upgrades)"
log_info "Objective: Enable unattended-upgrades service for daily automated security vulnerability patching."

PHASE7_ALREADY_CONFIGURED=false
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null || systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    PHASE7_ALREADY_CONFIGURED=true
  fi
fi

if [ "$PHASE7_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 7: Automatic security updates (unattended-upgrades) are already active at standard. Skipping..."
else
  log_step "7. Configuring unattended-upgrades..."
  apt-get install -y -qq unattended-upgrades apt-listchanges
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable unattended-upgrades --now >/dev/null 2>&1 || true
  log_success "Automatic security upgrades enabled."
fi

# ==================================================================
# PHASE 8 — Filesystem & Memory Protection (CIS Benchmark)
# ==================================================================
echo ""
log_step "Phase 8 — Filesystem & Memory Protection (CIS Benchmark)"
log_info "Objective: Secure shared memory /dev/shm (nodev, nosuid, noexec) and disable process core dumps."

PHASE8_ALREADY_CONFIGURED=false
SHM_CONFIGURED=false
if grep -E '\s/dev/shm\s' /etc/fstab 2>/dev/null | grep -q "nodev" && \
   grep -E '\s/dev/shm\s' /etc/fstab 2>/dev/null | grep -q "nosuid" && \
   grep -E '\s/dev/shm\s' /etc/fstab 2>/dev/null | grep -q "noexec"; then
  SHM_CONFIGURED=true
fi

COREDUMP_CONFIGURED=false
if [ -f /etc/security/limits.d/10-hardening-coredump.conf ] && grep -q '\* hard core 0' /etc/security/limits.d/10-hardening-coredump.conf; then
  COREDUMP_CONFIGURED=true
fi

if [ "$SHM_CONFIGURED" = true ] && [ "$COREDUMP_CONFIGURED" = true ]; then
  PHASE8_ALREADY_CONFIGURED=true
fi

if [ "$PHASE8_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 8: /dev/shm and core dump restrictions are already configured at standard. Skipping..."
else
  log_step "8.1 Securing shared memory (/dev/shm) with nodev, nosuid, and noexec..."
  if grep -E '\s/dev/shm\s' /etc/fstab >/dev/null 2>&1; then
    sed -i -E 's|(\s/dev/shm\s+tmpfs\s+)[^\s]+|\1defaults,nodev,nosuid,noexec|' /etc/fstab
  else
    echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" >> /etc/fstab
  fi
  mount -o remount,nodev,nosuid,noexec /dev/shm 2>/dev/null || true
  log_success "Shared memory (/dev/shm) secured."

  log_step "8.2 Disabling process core dumps (preventing RAM credential exposure)..."
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/10-hardening-coredump.conf <<'EOF'
# Disable core dumps for all users and services (CIS Benchmark)
* hard core 0
* soft core 0
EOF

  if [ -d /etc/systemd ]; then
    mkdir -p /etc/systemd/coredump.conf.d
    cat > /etc/systemd/coredump.conf.d/disable.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  fi
  log_success "Core dump generation disabled in PAM limits and systemd."
fi

# ==================================================================
# PHASE 9 — Kernel Modules Hardening (Disabling Obsolete Protocols)
# ==================================================================
echo ""
log_step "Phase 9 — Legacy Network Protocols Blacklist (Modprobe)"
log_info "Objective: Blacklist obsolete and uncommon protocols vulnerable to exploits (dccp, sctp, rds, tipc, firewire-core)."

PHASE9_ALREADY_CONFIGURED=false
if [ -f /etc/modprobe.d/hardening.conf ]; then
  if grep -q "install dccp /bin/true" /etc/modprobe.d/hardening.conf && \
     grep -q "install sctp /bin/true" /etc/modprobe.d/hardening.conf && \
     grep -q "install rds /bin/true" /etc/modprobe.d/hardening.conf && \
     grep -q "install tipc /bin/true" /etc/modprobe.d/hardening.conf; then
    PHASE9_ALREADY_CONFIGURED=true
  fi
fi

if [ "$PHASE9_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 9: Legacy protocol blacklist (modprobe) is already configured at standard. Skipping..."
else
  log_step "9. Disabling unused and legacy network protocols in /etc/modprobe.d/hardening.conf..."
  mkdir -p /etc/modprobe.d
  cat > /etc/modprobe.d/hardening.conf <<'EOF'
# Disable uncommon protocols vulnerable to privilege escalation (CIS Benchmark)
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
install firewire-core /bin/true
EOF
  log_success "Uncommon network protocols (dccp, sctp, rds, tipc, firewire-core) disabled."
fi

# ==================================================================
# PHASE 10 — System Auditing & Intrusion Logging
# ==================================================================
echo ""
log_step "Phase 10 — System Security Auditing (Auditd & Lynis)"
log_info "Objective: Install and activate the auditd daemon for kernel-level security event tracing."

PHASE10_ALREADY_CONFIGURED=false
if systemctl is-active --quiet auditd 2>/dev/null; then
  if [ "$RUN_AUDIT" = false ] || [ -f /var/log/lynis-hardening-report.txt ]; then
    PHASE10_ALREADY_CONFIGURED=true
  fi
fi

if [ "$PHASE10_ALREADY_CONFIGURED" = true ]; then
  log_success "Phase 10: System audit daemon (auditd) is already installed and active at standard. Skipping..."
  if [ "$RUN_AUDIT" = true ] && [ -f /var/log/lynis-hardening-report.txt ]; then
    LYNIS_SCORE="$(grep -E 'Hardening index' /var/log/lynis-hardening-report.txt | awk -F: '{print $2}' | tr -d ' ' || true)"
    LYNIS_SCORE="${LYNIS_SCORE:-N/A}"
    log_info "Previous Lynis report found: Hardening Index ${C_BOLD}${LYNIS_SCORE}${C_RESET} (/var/log/lynis-hardening-report.txt)"
  fi
else
  log_step "10.1 Installing and configuring auditd system audit daemon..."
  apt-get install -y -qq auditd
  systemctl enable auditd >/dev/null 2>&1 || true
  systemctl start auditd 2>/dev/null || true
  log_success "auditd service installed and active."

  if [ "$RUN_AUDIT" = true ]; then
    log_step "10.2 Installing Lynis and running security audit baseline..."
    apt-get install -y -qq lynis
    log_info "Executing Lynis security audit (this may take 1-2 minutes)..."
    lynis audit system --quick --no-colors > /var/log/lynis-hardening-report.txt 2>&1 || true
    LYNIS_SCORE="$(grep -E 'Hardening index' /var/log/lynis-hardening-report.txt | awk -F: '{print $2}' | tr -d ' ' || true)"
    LYNIS_SCORE="${LYNIS_SCORE:-N/A}"
    log_success "Lynis audit complete! Hardening Index: ${C_BOLD}${LYNIS_SCORE}${C_RESET} (Report: /var/log/lynis-hardening-report.txt)"
  fi
fi

# ==================================================================
# PHASE 11 — Real-Time SSH Login Alerts (Telegram & Webhook)
# ==================================================================
echo ""
log_step "Phase 11 — Real-Time SSH Login Alerts (PAM)"
log_info "Objective: Dispatch instant notifications upon every SSH login to the server (Optional)."

if { [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; } || [ -n "$WEBHOOK_URL" ]; then
  # Credentials live in a root-only config file (never inside the world-readable script).
  # printf %q keeps any character (&, |, quotes) intact when the file is sourced.
  ALERT_CONF_DESIRED="$(printf 'TG_BOT_TOKEN=%q\nTG_CHAT_ID=%q\nWEBHOOK_URL=%q\n' "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$WEBHOOK_URL")"

  PHASE11_ALREADY_CONFIGURED=false
  if [ -f /usr/local/bin/ssh-login-alert.sh ] && grep -qF 'ALERT_CONF="/etc/vps-hardening/alert.conf"' /usr/local/bin/ssh-login-alert.sh && \
     [ -f /etc/vps-hardening/alert.conf ] && [ "$(cat /etc/vps-hardening/alert.conf)" = "$ALERT_CONF_DESIRED" ] && \
     [ -f /etc/pam.d/sshd ] && grep -q 'ssh-login-alert.sh' /etc/pam.d/sshd; then
    PHASE11_ALREADY_CONFIGURED=true
  fi

  if [ "$PHASE11_ALREADY_CONFIGURED" = true ]; then
    log_success "Phase 11: Real-time SSH login alerts (PAM) are already configured at standard. Skipping..."
  else
    log_step "11.1 Storing alert credentials in /etc/vps-hardening/alert.conf (root only, mode 600)..."
    install -d -m 700 -o root -g root /etc/vps-hardening
    (umask 077 && printf '%s\n' "$ALERT_CONF_DESIRED" > /etc/vps-hardening/alert.conf)
    chown root:root /etc/vps-hardening/alert.conf
    chmod 600 /etc/vps-hardening/alert.conf

    log_step "11.2 Installing dispatcher /usr/local/bin/ssh-login-alert.sh and PAM session hook..."
    cat > /usr/local/bin/ssh-login-alert.sh <<'EOF'
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
EOF
    chown root:root /usr/local/bin/ssh-login-alert.sh
    chmod 700 /usr/local/bin/ssh-login-alert.sh

    if [ -f /etc/pam.d/sshd ]; then
      [ -f /etc/pam.d/sshd.bak ] || cp /etc/pam.d/sshd /etc/pam.d/sshd.bak
      if ! grep -q 'ssh-login-alert.sh' /etc/pam.d/sshd; then
        echo "session optional pam_exec.so seteuid /usr/local/bin/ssh-login-alert.sh" >> /etc/pam.d/sshd
      fi
    fi

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      log_info "Testing Telegram bot connection..."
      curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=🛡️ VPS Hardening Alert Activated for $(hostname) on port ${SSH_PORT}" >/dev/null 2>&1 || true
      log_success "Telegram SSH login alert configured and connected to Chat ID: ${TG_CHAT_ID}."
    else
      log_success "PAM SSH login alert webhook configured."
    fi
  fi
else
  log_info "Phase 11: Real-time SSH login alerts not configured (Optional phase — inactive if Telegram or Webhook was not provided)."
fi

# ==================================================================
# POST-HARDENING VERIFICATION & AUDIT SUITE
# ==================================================================
if [ "$RUN_VERIFY" = true ]; then
  echo ""
  log_step "Running automated post-hardening security validation suite..."
  if [ -x /usr/local/bin/verify-hardening ]; then
    /usr/local/bin/verify-hardening --port "$SSH_PORT" --user "$NOVO_USUARIO" || true
  elif [ -f "$SCRIPT_DIR/verify.sh" ]; then
    bash "$SCRIPT_DIR/verify.sh" --port "$SSH_PORT" --user "$NOVO_USUARIO" || true
  fi
fi

# ==================================================================
# FINAL SUMMARY AND CRITICAL INSTRUCTIONS
# ==================================================================
DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "VPS_IP_ADDRESS")

echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}                   ✔ HARDENING APPLIED SUCCESSFULLY!                          ${C_RESET}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo ""
echo -e "${C_RED}${C_BOLD}  ⚠️  CRITICAL: DO NOT CLOSE THIS TERMINAL SESSION YET!${C_RESET}"
echo ""
echo -e "  Follow the steps below in a ${C_BOLD}NEW terminal session${C_RESET} on your local computer:"
echo ""
echo -e "  ${C_BOLD}Step 1:${C_RESET} Test the new SSH connection using your SSH key:"
echo -e "    ${C_CYAN}ssh -i ~/.ssh/id_ed25519 -p ${SSH_PORT} ${NOVO_USUARIO}@${DETECTED_IP}${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Step 2:${C_RESET} Verify that sudo privileges work for the new user:"
echo -e "    ${C_CYAN}sudo whoami${C_RESET}      ${C_BLUE}# Expected output: root${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Step 3:${C_RESET} ONLY after confirming steps 1 and 2, lock the root account password:"
echo -e "    ${C_CYAN}sudo passwd -l root${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Active Security Defenses:${C_RESET}"
echo -e "    - OpenSSH listening on port ${SSH_PORT} (key-only authentication, root login disabled)"
echo -e "    - UFW Firewall active (default-deny policy, rate-limited SSH$([ -n "$ALLOW_PORTS" ] && echo ", allowed ports: ${ALLOW_PORTS}"))"
echo -e "    - Fail2ban active with progressive ban escalation (sshd jail)"
echo -e "    - Kernel hardening active (${VIRT_ENV} profile)"
echo -e "    - Network throughput:  TCP BBR Congestion Control & Fair Queuing (FQ)"
echo -e "    - Shared memory (/dev/shm) secured with nodev, nosuid, noexec"
echo -e "    - Process coredumps disabled (fs.suid_dumpable=0, limits.conf)"
echo -e "    - Obsolete network protocols disabled (dccp, sctp, rds, tipc, firewire)"
echo -e "    - System security auditing active (auditd)"
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
  echo -e "    - Telegram SSH login alerts active (Chat ID: ${TG_CHAT_ID})"
elif [ -n "$WEBHOOK_URL" ]; then
  echo -e "    - Real-time SSH login notifications configured via PAM"
else
  echo -e "    - SSH login alerts:    Not configured (optional — active only if Telegram or Webhook is provided)"
fi
  if [ "$RUN_AUDIT" = true ]; then
    echo -e "    - Lynis audit complete (Hardening Index: ${C_GREEN}${LYNIS_SCORE}${C_RESET}, Report: /var/log/lynis-hardening-report.txt)"
  fi
  echo -e "    - Verification suite:  run anytime via '${C_CYAN}sudo verify-hardening${C_RESET}' or '${C_CYAN}sudo ./verify.sh${C_RESET}'"
echo ""
echo -e "  ${C_BOLD}Rollback Snapshot:${C_RESET}"
if [ -n "$ROLLBACK_SNAPSHOT_PATH" ]; then
  echo -e "    - Snapshot archive: ${C_CYAN}${ROLLBACK_SNAPSHOT_PATH}${C_RESET}"
  echo -e "    - Instant rollback: ${C_CYAN}sudo hardening-rollback${C_RESET} (or ${C_CYAN}sudo ./rollback.sh${C_RESET} / ${C_CYAN}sudo ./hardening.sh --rollback${C_RESET})"
fi
echo ""
echo -e "  ${C_BOLD}Backups Created:${C_RESET}"
echo -e "    - /etc/ssh/sshd_config.bak and /etc/ssh/sshd_config.d/*.conf.bak (SSH backups)"
if { [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; } || [ -n "$WEBHOOK_URL" ]; then
  echo -e "    - /etc/pam.d/sshd.bak (PAM SSH backup)"
fi
echo -e "    - /home/*/.ssh/authorized_keys.disabled (disabled default provider keys)"
echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"

# ==================================================================
# SAFETY TIMER CONFIRMATION
# ==================================================================
if [ "$SAFETY_TIMER_ARMED" = true ]; then
  # Fresh window from now, so the user has the full time to test the new login
  arm_safety_timer "$SAFETY_TIMER_MINUTES"
fi
if [ "$SAFETY_TIMER_ARMED" = true ]; then
  echo ""
  echo -e "${C_YELLOW}${C_BOLD}  ⏱️  SAFETY TIMER ACTIVE — the system will be rolled back automatically in ${SAFETY_TIMER_MINUTES} minute(s).${C_RESET}"
  echo -e "  1) Test the login in a ${C_BOLD}NEW terminal${C_RESET} (Step 1 above)."
  echo -e "  2) If it works, type ${C_BOLD}CONFIRM${C_RESET} below to keep the hardening."
  echo -e "  ${C_DIM}You can also confirm later with: sudo systemctl stop ${SAFETY_TIMER_UNIT}.timer${C_RESET}"
  echo ""
  while true; do
    CONFIRM_TIMER=""
    read_input "${C_YELLOW}?${C_RESET} Type CONFIRM to keep the changes (Enter = leave timer running): " CONFIRM_TIMER ""
    if [ "${CONFIRM_TIMER^^}" = "CONFIRM" ]; then
      disarm_safety_timer
      log_success "Safety timer cancelled. Hardening is now permanent."
      break
    elif [ -z "$CONFIRM_TIMER" ]; then
      log_warn "Timer still running: automatic rollback at $(date -d "+${SAFETY_TIMER_MINUTES} min" +%H:%M) unless you run 'sudo systemctl stop ${SAFETY_TIMER_UNIT}.timer'."
      break
    else
      log_warn "Please type exactly CONFIRM (or press Enter to leave the timer running)."
    fi
  done
  echo ""
fi
