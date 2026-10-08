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

# Helper function for safe terminal input (even when piped from `curl ... | bash`)
read_input() {
  local prompt="$1"
  local varname="$2"
  local default_val="${3:-}"
  local value=""

  if [ -c /dev/tty ]; then
    read -r -p "$(echo -e "$prompt")" value < /dev/tty || true
  else
    read -r -p "$(echo -e "$prompt")" value || true
  fi

  if [ -z "$value" ] && [ -n "$default_val" ]; then
    value="$default_val"
  fi
  eval "$varname=\"$value\""
}

# ------------------------------------------------------------------
# Quick Help Check (-h / --help)
# ------------------------------------------------------------------
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    cat <<EOF
Usage: sudo $0 [options] or sudo $0 <user> "<ssh_key>" [port] [timezone]

Options:
  -u, --user <username>       Name of the new administrative user
  -k, --key "<ssh_key>"       Authorized public SSH key (ed25519, rsa, ecdsa)
  -p, --port <port>           Custom SSH port (1024-65535, default: 52211)
  -t, --timezone <tz>         System timezone (e.g., UTC, America/New_York, America/Sao_Paulo)
  -a, --allow-ports <ports>   Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp)
  --dry-run                   Simulate actions without making actual changes to the system
  --rollback [archive]        Restore system configuration from pre-hardening snapshot
  --tg-token <token>          Telegram Bot Token (from @BotFather) for login alerts
  --tg-chat <chat_id>         Telegram Chat ID (from @userinfobot) for login alerts
  -w, --webhook <url>         Discord/Custom Webhook URL for real-time SSH login alerts
  --audit, --lynis            Run Lynis security audit scan after hardening
  --no-verify                 Skip automatic post-hardening verification tests
  -y, --yes                   Skip interactive confirmation prompt
  -h, --help                  Display this help message

Examples:
  sudo $0 operator "ssh-ed25519 AAAAC3... vps-access" 52211
  sudo $0 -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -a 80,443 --tg-token "..." --tg-chat "..." -y
  sudo $0 --dry-run           # Test run simulation
  sudo $0 --rollback          # Restore previous configuration from latest backup
EOF
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

show_help() {
  cat <<EOF
Usage: sudo $0 [options] or sudo $0 <user> "<ssh_key>" [port] [timezone]

Options:
  -u, --user <username>       Name of the new administrative user
  -k, --key "<ssh_key>"       Authorized public SSH key (raw string, gh:username, or URL)
  -p, --port <port>           Custom SSH port (1024-65535, default: 52211)
  -t, --timezone <tz>         System timezone (e.g., UTC, America/New_York, America/Sao_Paulo)
  -a, --allow-ports <ports>   Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp)
  --dry-run                   Simulate actions without making actual changes to the system
  --rollback [archive]        Restore system configuration from pre-hardening snapshot
  --tg-token <token>          Telegram Bot Token (from @BotFather) for login alerts
  --tg-chat <chat_id>         Telegram Chat ID (from @userinfobot) for login alerts
  -w, --webhook <url>         Discord/Custom Webhook URL for real-time SSH login alerts
  --audit, --lynis            Run Lynis security audit scan after hardening
  --no-verify                 Skip automatic post-hardening verification tests
  -y, --yes                   Skip interactive confirmation prompt
  -h, --help                  Display this help message

Examples:
  sudo $0 operator "ssh-ed25519 AAAAC3... vps-access" 52211
  sudo $0 -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -a 80,443 --tg-token "..." --tg-chat "..." -y
  sudo $0 --dry-run           # Test run simulation
  sudo $0 --rollback          # Restore previous configuration from latest backup
EOF
  exit 0
}

# ------------------------------------------------------------------
# Rollback Implementation
# ------------------------------------------------------------------
do_rollback() {
  local target_backup="${1:-}"
  local backup_dir="/var/backups/vps_hardening"

  echo ""
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}          VPS HARDENING SYSTEM ROLLBACK${C_RESET}"
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo ""

  if [ -z "$target_backup" ]; then
    if [ -f "$backup_dir/latest.tar.gz" ]; then
      target_backup="$backup_dir/latest.tar.gz"
    elif compgen -G "$backup_dir/hardening_backup_*.tar.gz" > /dev/null; then
      target_backup=$(ls -t "$backup_dir"/hardening_backup_*.tar.gz 2>/dev/null | head -n 1)
    fi
  fi

  if [ -z "$target_backup" ] || [ ! -f "$target_backup" ]; then
    log_error "No rollback backup archive found in '$backup_dir'!"
    echo "Usage: sudo $0 --rollback [/path/to/hardening_backup.tar.gz]"
    exit 1
  fi

  log_warn "Target snapshot: ${C_BOLD}${target_backup}${C_RESET}"
  if [ "$ASSUME_YES" = false ]; then
    read -r -p "Are you sure you want to restore previous system configurations? [y/N]: " confirm_rb || true
    if [[ ! "$confirm_rb" =~ ^[YySs]$ ]]; then
      log_info "Rollback aborted by user."
      exit 0
    fi
  fi

  log_info "Restoring files from snapshot..."
  tar -xzf "$target_backup" -C /

  log_info "Reloading restored kernel parameters..."
  sysctl --system >/dev/null 2>&1 || true

  log_info "Validating OpenSSH configuration..."
  if sshd -t 2>/dev/null; then
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
    log_success "SSH service restarted with restored configuration."
  else
    log_warn "Warning: sshd configuration check reported errors. Check /etc/ssh/."
  fi

  log_info "Restarting Fail2ban..."
  systemctl restart fail2ban 2>/dev/null || true

  echo ""
  log_success "Rollback successfully completed! System configurations restored from: $target_backup"
  exit 0
}

create_rollback_snapshot() {
  local backup_dir="/var/backups/vps_hardening"
  local timestamp="$(date +%Y%m%d_%H%M%S)"
  local snapshot_archive="${backup_dir}/hardening_backup_${timestamp}.tar.gz"

  mkdir -p "$backup_dir"
  log_info "Creating pre-hardening rollback snapshot..."

  local files_to_backup=()
  for item in \
    /etc/ssh \
    /etc/pam.d/sshd \
    /etc/sysctl.d \
    /etc/fstab \
    /etc/default/ufw \
    /etc/ufw \
    /etc/fail2ban \
    /etc/security/limits.d \
    /etc/modprobe.d \
    /etc/apt/apt.conf.d/20auto-upgrades; do
    if [ -e "$item" ]; then
      files_to_backup+=("${item#/}")
    fi
  done

  if [ ${#files_to_backup[@]} -gt 0 ]; then
    tar -czf "$snapshot_archive" -C / "${files_to_backup[@]}" 2>/dev/null || true
    ln -sf "$snapshot_archive" "$backup_dir/latest.tar.gz" 2>/dev/null || true
    ROLLBACK_SNAPSHOT_PATH="$snapshot_archive"
    log_success "Pre-hardening snapshot created at: $snapshot_archive"
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
        *) log_error "Unknown parameter: $1"; show_help ;;
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
  do_rollback "$ROLLBACK_FILE"
fi

# ------------------------------------------------------------------
# Interactive Mode (if username or SSH key is missing)
# ------------------------------------------------------------------
if [ -z "$NOVO_USUARIO" ] || [ -z "$CHAVE_SSH" ]; then
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}          VPS HARDENING CONFIGURATION WIZARD${C_RESET}"
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo ""

  if [ -z "$NOVO_USUARIO" ]; then
    read_input "${C_YELLOW}?${C_RESET} New administrative username [operator]: " NOVO_USUARIO "operator"
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

  read_input "${C_YELLOW}?${C_RESET} Server Timezone [${TIMEZONE}]: " INPUT_TZ "$TIMEZONE"
  TIMEZONE="$INPUT_TZ"

  if [ -z "$ALLOW_PORTS" ]; then
    read_input "${C_YELLOW}?${C_RESET} Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp) [none]: " INPUT_PORTS ""
    ALLOW_PORTS="$INPUT_PORTS"
  fi

  if [ -z "$TG_BOT_TOKEN" ] && [ -z "$WEBHOOK_URL" ]; then
    echo ""
    log_info "Fase 11 — Alertas de Login SSH em Tempo Real:"
    echo -e "    ${C_DIM}ℹ️  Esta fase é opcional. Se não for informado Telegram ou Webhook, ela NÃO será ativada.${C_RESET}"
    read_input "${C_YELLOW}?${C_RESET} Deseja configurar alertas instantâneos via Telegram no login SSH? [y/N]: " ENABLE_TG "N"
    if [[ "$ENABLE_TG" =~ ^[YySs]$ ]]; then
      read_input "    ${C_YELLOW}→${C_RESET} Telegram Bot Token (do @BotFather): " TG_BOT_TOKEN ""
      read_input "    ${C_YELLOW}→${C_RESET} Telegram Chat ID (do @userinfobot): " TG_CHAT_ID ""
    else
      read_input "${C_YELLOW}?${C_RESET} URL alternativa de Webhook (Discord / Slack / Custom) [pular/Enter]: " INPUT_WEBHOOK ""
      WEBHOOK_URL="$INPUT_WEBHOOK"
    fi
    if [ -z "$TG_BOT_TOKEN" ] && [ -z "$WEBHOOK_URL" ]; then
      log_info "Alertas SSH: Nenhum canal informado. Fase 11 permanecerá desativada."
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

# ------------------------------------------------------------------
# Plan Confirmation
# ------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}--- Hardening Parameters ---${C_RESET}"
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
  echo -e "  SSH Login Alert:   ${C_YELLOW}Não Configurado (Opcional — só ativa se informado Telegram ou Webhook)${C_RESET}"
fi
echo -e "  Lynis Audit Scan:  ${C_GREEN}${RUN_AUDIT}${C_RESET}"
if [ "$DRY_RUN" = true ]; then
  echo -e "  Execution Mode:    ${C_YELLOW}${C_BOLD}DRY-RUN (SIMULATION ONLY)${C_RESET}"
fi
echo -e "${C_BOLD}----------------------------${C_RESET}"

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
  echo -e "${C_YELLOW}${C_BOLD}==============================================================================${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}   ⚠️  SIMULATION MODE (DRY-RUN) ACTIVE — NO SYSTEM CHANGES WILL BE MADE       ${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}==============================================================================${C_RESET}"
  echo ""
  echo -e "${C_CYAN}${C_BOLD}[*] Running full pre-flight simulation of all 11 hardening phases...${C_RESET}"
  echo ""
  
  echo -e "${C_BOLD}Phase 1: Base System & Time Synchronization${C_RESET}"
  echo -e "  [DRY-RUN] Would update package lists: apt-get update -qq"
  echo -e "  [DRY-RUN] Would ensure essential dependencies: apt-get install -y sudo curl"
  echo -e "  [DRY-RUN] Would upgrade existing packages: apt-get upgrade -y"
  echo -e "  [DRY-RUN] Would configure system timezone to '${TIMEZONE}' via timedatectl"
  echo -e "  [DRY-RUN] Would enable network time synchronization (NTP)"
  echo ""

  echo -e "${C_BOLD}Phase 2: Administrative User Provisioning & Neutralization${C_RESET}"
  echo -e "  [DRY-RUN] Would verify or create user '${NOVO_USUARIO}' with bash shell"
  echo -e "  [DRY-RUN] Would append '${NOVO_USUARIO}' to sudo group (usermod -aG sudo ${NOVO_USUARIO})"
  echo -e "  [DRY-RUN] Would enforce password setup for sudo authentication"
  echo -e "  [DRY-RUN] Would neutralize default accounts (ubuntu, debian, admin, centos):"
  echo -e "            - Lock passwords (passwd -l)"
  echo -e "            - Set shell to /usr/sbin/nologin"
  echo -e "            - Rename .ssh/authorized_keys to authorized_keys.disabled"
  echo ""

  echo -e "${C_BOLD}Phase 3: OpenSSH Cryptographic & Protocol Hardening${C_RESET}"
  echo -e "  [DRY-RUN] Would create ${NOVO_USUARIO} SSH directory: ~/.ssh (mode 700)"
  echo -e "  [DRY-RUN] Would install public key in ~/.ssh/authorized_keys (mode 600)"
  echo -e "  [DRY-RUN] Would backup /etc/ssh/sshd_config to /etc/ssh/sshd_config.bak"
  echo -e "  [DRY-RUN] Would sanitize /etc/ssh/sshd_config and neutralize overriding directives"
  echo -e "  [DRY-RUN] Would deploy drop-in configuration /etc/ssh/sshd_config.d/00-hardening.conf:"
  echo -e "            - Port ${SSH_PORT}"
  echo -e "            - PermitRootLogin no"
  echo -e "            - PasswordAuthentication no"
  echo -e "            - PubkeyAuthentication yes"
  echo -e "            - MaxAuthTries 3"
  echo -e "            - X11Forwarding no"
  echo -e "            - AllowUsers ${NOVO_USUARIO}"
  echo -e "  [DRY-RUN] Would test OpenSSH syntax: sshd -t"
  echo -e "  [DRY-RUN] Would restart ssh/sshd systemd service"
  echo ""

  echo -e "${C_BOLD}Phase 4: UFW Stateful Firewall Automation${C_RESET}"
  echo -e "  [DRY-RUN] Would ensure ufw package is installed"
  echo -e "  [DRY-RUN] Would configure default policies: incoming: deny, outgoing: allow, routed: deny"
  echo -e "  [DRY-RUN] Would rate-limit SSH access on custom port: ufw limit ${SSH_PORT}/tcp"
  if [ -n "$ALLOW_PORTS" ]; then
    IFS=',' read -ra ADDR <<< "$ALLOW_PORTS"
    for p in "${ADDR[@]}"; do
      p_clean=$(echo "$p" | tr -d '[:space:]')
      [ -n "$p_clean" ] && echo -e "  [DRY-RUN] Would open additional firewall port: ufw allow ${p_clean}"
    done
  fi
  echo -e "  [DRY-RUN] Would enable firewall: ufw --force enable"
  echo ""

  echo -e "${C_BOLD}Phase 5: Fail2ban Intrusion Prevention System${C_RESET}"
  echo -e "  [DRY-RUN] Would install fail2ban package"
  echo -e "  [DRY-RUN] Would configure /etc/fail2ban/jail.d/00-ssh-hardening.local:"
  echo -e "            - jail: sshd, port: ${SSH_PORT}, maxretry: 5, findtime: 10m, bantime: 1h"
  echo -e "  [DRY-RUN] Would enable and start fail2ban systemd service"
  echo ""

  echo -e "${C_BOLD}Phase 6: Kernel Sysctl Network & Memory Hardening${C_RESET}"
  echo -e "  [DRY-RUN] Detected virtualization hypervisor: ${VIRT_ENV}"
  echo -e "  [DRY-RUN] Would deploy /etc/sysctl.d/99-hardening.conf:"
  echo -e "            - TCP SYN cookies enabled (DoS mitigation)"
  echo -e "            - IP spoofing / reverse-path filtering (rp_filter = 1)"
  echo -e "            - ICMP redirect acceptance/sending disabled"
  echo -e "            - Source routing disabled"
  echo -e "            - Address space layout randomization (ASLR = 2)"
  echo -e "            - Core dump suid restrictions (fs.suid_dumpable = 0)"
  echo -e "            - TCP BBR congestion control & fair queuing (FQ) enabled"
  echo -e "  [DRY-RUN] Would load kernel parameters: sysctl --system"
  echo ""

  echo -e "${C_BOLD}Phase 7: Automated Security Updates (Unattended-Upgrades)${C_RESET}"
  echo -e "  [DRY-RUN] Would install unattended-upgrades and apt-listchanges"
  echo -e "  [DRY-RUN] Would configure /etc/apt/apt.conf.d/20auto-upgrades for daily updates"
  echo -e "  [DRY-RUN] Would restart unattended-upgrades systemd service"
  echo ""

  echo -e "${C_BOLD}Phase 8: Shared Memory & /tmp Hardening (CIS Benchmark)${C_RESET}"
  echo -e "  [DRY-RUN] Would configure /dev/shm in /etc/fstab with nodev,nosuid,noexec"
  echo -e "  [DRY-RUN] Would remount /dev/shm with restrictive mount options: mount -o remount,nodev,nosuid,noexec /dev/shm"
  echo ""

  echo -e "${C_BOLD}Phase 9: Process Core Dump Disablement${C_RESET}"
  echo -e "  [DRY-RUN] Would deploy /etc/security/limits.d/10-hardening-coredump.conf (* hard core 0)"
  echo -e "  [DRY-RUN] Would configure /etc/systemd/coredump.conf (Storage=none, ProcessSizeMax=0)"
  echo ""

  echo -e "${C_BOLD}Phase 10: Legacy Kernel Network Protocols Blacklist${C_RESET}"
  echo -e "  [DRY-RUN] Would deploy /etc/modprobe.d/hardening.conf:"
  echo -e "            - install dccp /bin/true"
  echo -e "            - install sctp /bin/true"
  echo -e "            - install rds /bin/true"
  echo -e "            - install tipc /bin/true"
  echo -e "            - install firewire-core /bin/true"
  echo ""

  echo -e "${C_BOLD}Phase 11: Security Auditing (Auditd & Lynis)${C_RESET}"
  echo -e "  [DRY-RUN] Would install and activate auditd service"
  if [ "$RUN_AUDIT" = true ]; then
    echo -e "  [DRY-RUN] Would install Lynis and run automated security benchmark: lynis audit system --quick"
  else
    echo -e "  [DRY-RUN] Lynis audit scan skipped (use --audit to enable)"
  fi
  echo ""

  if { [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; } || [ -n "$WEBHOOK_URL" ]; then
    echo -e "${C_BOLD}Phase 11: Real-Time SSH Login Alerts${C_RESET}"
    echo -e "  [DRY-RUN] Would install dispatcher script: /usr/local/bin/ssh-login-alert.sh"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      echo -e "  [DRY-RUN] Notification Provider: Telegram (Chat ID: ${TG_CHAT_ID})"
    else
      echo -e "  [DRY-RUN] Notification Provider: Webhook (${WEBHOOK_URL:0:30}...)"
    fi
    echo -e "  [DRY-RUN] Would attach asynchronous PAM session hook to /etc/pam.d/sshd"
    echo ""
  else
    echo -e "${C_BOLD}Phase 11: Real-Time SSH Login Alerts (Optional)${C_RESET}"
    echo -e "  [DRY-RUN] Não configurado — Se não for informado Telegram (--tg-token / --tg-chat) ou Webhook (--webhook), esta etapa não será ativada."
    echo ""
  fi

  echo -e "${C_BOLD}==============================================================================${C_RESET}"
  echo -e "${C_YELLOW}${C_BOLD}                   ✔ DRY-RUN SIMULATION COMPLETED!                           ${C_RESET}"
  echo -e "${C_BOLD}==============================================================================${C_RESET}"
  echo ""
  echo -e "  ${C_BOLD}Simulated Hardening Baseline:${C_RESET}"
  echo -e "    - Administrative User: ${NOVO_USUARIO} (sudo member, public key deployed)"
  echo -e "    - Hardened SSH Port:   ${SSH_PORT} (root login: no, password auth: no)"
  echo -e "    - UFW Firewall:        default-deny, limit port ${SSH_PORT}$([ -n "$ALLOW_PORTS" ] && echo ", allow: ${ALLOW_PORTS}")"
  echo -e "    - Fail2ban:            sshd jail on port ${SSH_PORT}"
  echo -e "    - Kernel sysctl:       security profile for '${VIRT_ENV}' hypervisor"
  echo -e "    - Network throughput:  TCP BBR Congestion Control & Fair Queuing (FQ)"
  echo -e "    - Shared Memory:       /dev/shm nodev,nosuid,noexec"
  echo -e "    - Process coredumps:   disabled in limits and systemd"
  echo -e "    - Kernel protocols:    dccp, sctp, rds, tipc, firewire-core disabled"
  echo -e "    - System auditing:     auditd active$([ "$RUN_AUDIT" = true ] && echo ", Lynis security benchmark scan")"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    echo -e "    - Telegram alerts:     configured for Chat ID ${TG_CHAT_ID}"
  elif [ -n "$WEBHOOK_URL" ]; then
    echo -e "    - SSH login alerts:    configured via webhook"
  fi
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
  echo ""
fi

log_info "Starting hardening process..."

# ==================================================================
# PHASE 1 — Base System & Time Synchronization
# ==================================================================
echo ""
log_step "Fase 1 — Sistema Base e Sincronização de Horário"
log_info "Objetivo: Atualizar repositórios, instalar utilitários essenciais (sudo, curl) e sincronizar o relógio via NTP."

PHASE1_ALREADY_CONFIGURED=false
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
NTP_SYNC="$(timedatectl status 2>/dev/null | grep -E 'NTP service: active|Network time on: yes|System clock synchronized: yes' || true)"

if command -v sudo >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && [ -n "$NTP_SYNC" ] && ([ "$CURRENT_TZ" = "$TIMEZONE" ] || [ -z "$TIMEZONE" ]); then
  PHASE1_ALREADY_CONFIGURED=true
fi

if [ "$PHASE1_ALREADY_CONFIGURED" = true ]; then
  log_success "Fase 1: Sistema base, ferramentas essenciais (sudo, curl), fuso ($TIMEZONE) e NTP já estão no padrão. Pulando..."
else
  log_step "1.1 Updating package repositories and installing baseline packages (sudo, curl)..."
  apt-get update -qq
  apt-get install -y -qq sudo curl
  apt-get upgrade -y -qq

  log_step "1.2 Configuring Timezone ($TIMEZONE) and NTP synchronization..."
  if timedatectl list-timezones | grep -qx "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE"
  else
    log_warn "Timezone '$TIMEZONE' not found on system. Keeping current timezone."
  fi
  timedatectl set-ntp true 2>/dev/null || true
  log_success "Base system updated and system clock synchronized."
fi

# ==================================================================
# PHASE 2 — User Accounts
# ==================================================================
echo ""
log_step "Fase 2 — Usuário Administrativo e Neutralização de Contas Cloud"
log_info "Objetivo: Provisionar usuário '${NOVO_USUARIO}' com privilégios sudo e travar contas padrão vulneráveis (ubuntu, debian, admin, etc.)."

PHASE2_ALREADY_CONFIGURED=false
if id "$NOVO_USUARIO" &>/dev/null && id -nG "$NOVO_USUARIO" 2>/dev/null | grep -qw "sudo"; then
  PASSWD_CHECK="$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")"
  if [[ ! "$PASSWD_CHECK" =~ ^(L|NP)$ ]]; then
    DEFAULTS_SECURE=true
    for u in ubuntu debian admin centos; do
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
  log_success "Fase 2: Usuário '${NOVO_USUARIO}' e contas padrão de cloud já estão configurados no padrão. Pulando..."
else
  log_step "2.1 Creating or configuring user '${NOVO_USUARIO}'..."
  if id "$NOVO_USUARIO" &>/dev/null; then
    log_info "User '${NOVO_USUARIO}' already exists, ensuring sudo group membership."
  else
    useradd -m -s /bin/bash "$NOVO_USUARIO"
    log_success "User '${NOVO_USUARIO}' created successfully."
  fi
  if ! getent group sudo >/dev/null 2>&1; then
    groupadd sudo
  fi
  usermod -aG sudo "$NOVO_USUARIO"

  # Set password if account is locked or has no password (required for sudo)
  PASSWD_STATUS="$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")"
  if [[ "$PASSWD_STATUS" =~ ^(L|NP)$ ]]; then
    echo ""
    log_warn "ATTENTION: Set the password for '${NOVO_USUARIO}' (required for sudo):"
    if [ -c /dev/tty ]; then
      passwd "$NOVO_USUARIO" < /dev/tty
    else
      passwd "$NOVO_USUARIO"
    fi
    echo ""
  fi

  log_step "2.2 Neutralizing cloud provider default administrative accounts..."
  for u in ubuntu debian admin centos; do
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
log_step "Fase 3 — Hardening Criptográfico do OpenSSH"
log_info "Objetivo: Migrar para a porta $SSH_PORT, desativar senhas/root e permitir exclusivamente login com chave SSH."

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
  log_success "Fase 3: OpenSSH já está configurado no padrão (porta $SSH_PORT, autenticação exclusiva por chave). Pulando..."
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
  if ! sshd -t; then
    log_error "SSH configuration syntax check failed! Aborting service reload to prevent lockout."
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    exit 1
  fi
  log_success "SSH configuration syntax is valid."

  log_step "3.5 Resolving socket activation (Ubuntu 22.10+) and restarting SSH..."
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
log_step "Fase 4 — Firewall Stateful (UFW)"
log_info "Objetivo: Ativar o firewall com bloqueio padrão de entrada (default-deny) e rate-limiting na porta $SSH_PORT."

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
  log_success "Fase 4: UFW Firewall já está ativo e configurado no padrão com a porta $SSH_PORT. Pulando..."
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
log_step "Fase 5 — Prevenção de Intrusão (Fail2ban)"
log_info "Objetivo: Proteger contra tentativas repetidas de força bruta com banimento progressivo na porta $SSH_PORT."

PHASE5_ALREADY_CONFIGURED=false
if command -v fail2ban-client >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
  if [ -f /etc/fail2ban/jail.local ] && grep -qE "^\s*port\s*=\s*$SSH_PORT\b" /etc/fail2ban/jail.local; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
      PHASE5_ALREADY_CONFIGURED=true
    fi
  fi
fi

if [ "$PHASE5_ALREADY_CONFIGURED" = true ]; then
  log_success "Fase 5: Fail2ban já está ativo e configurado no padrão monitorando a porta $SSH_PORT. Pulando..."
else
  log_step "5. Installing and configuring fail2ban and tmux..."
  apt-get install -y -qq fail2ban tmux

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
log_step "Fase 6 — Hardening do Kernel (sysctl) e Otimização de Rede"
log_info "Objetivo: Aplicar proteções de rede anti-spoofing, mitigação de SYN flood, ASLR, restrição de ponteiros e TCP BBR."

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
  log_success "Fase 6: Parâmetros de kernel (sysctl) e otimizações de rede já estão no padrão ($VIRT_ENV). Pulando..."
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
log_step "Fase 7 — Atualizações Automáticas de Segurança (Unattended-Upgrades)"
log_info "Objetivo: Habilitar o serviço unattended-upgrades para correções de vulnerabilidades automáticas diárias."

PHASE7_ALREADY_CONFIGURED=false
if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null || systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    PHASE7_ALREADY_CONFIGURED=true
  fi
fi

if [ "$PHASE7_ALREADY_CONFIGURED" = true ]; then
  log_success "Fase 7: Atualizações automáticas de segurança (unattended-upgrades) já estão ativas no padrão. Pulando..."
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
log_step "Fase 8 — Proteção do Sistema de Arquivos e Memória (CIS Benchmark)"
log_info "Objetivo: Proteger a memória compartilhada /dev/shm (nodev, nosuid, noexec) e desativar core dumps de processos."

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
  log_success "Fase 8: /dev/shm e desativação de coredumps já estão configurados no padrão. Pulando..."
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
log_step "Fase 9 — Blacklist de Protocolos de Rede Legados (Modprobe)"
log_info "Objetivo: Bloquear protocolos obsoletos propensos a exploração de vulnerabilidades (dccp, sctp, rds, tipc, firewire-core)."

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
  log_success "Fase 9: Blacklist de protocolos legados (modprobe) já está configurada no padrão. Pulando..."
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
log_step "Fase 10 — Auditoria de Segurança do Sistema (Auditd & Lynis)"
log_info "Objetivo: Instalar e ativar o serviço auditd para auditoria e rastreamento de eventos de segurança no kernel."

PHASE10_ALREADY_CONFIGURED=false
if systemctl is-active --quiet auditd 2>/dev/null; then
  if [ "$RUN_AUDIT" = false ] || [ -f /var/log/lynis-hardening-report.txt ]; then
    PHASE10_ALREADY_CONFIGURED=true
  fi
fi

if [ "$PHASE10_ALREADY_CONFIGURED" = true ]; then
  log_success "Fase 10: Subsistema de auditoria (auditd) já está instalado e ativo no padrão. Pulando..."
else
  log_step "10.1 Installing and configuring auditd system audit daemon..."
  apt-get install -y -qq auditd
  systemctl enable auditd >/dev/null 2>&1 || true
  systemctl start auditd 2>/dev/null || true
  log_success "auditd service installed and active."

  LYNIS_SCORE="N/A"
  if [ "$RUN_AUDIT" = true ]; then
    log_step "10.2 Installing Lynis and running security audit baseline..."
    apt-get install -y -qq lynis
    log_info "Executing Lynis security audit (this may take 1-2 minutes)..."
    lynis audit system --quick --no-colors > /var/log/lynis-hardening-report.txt 2>&1 || true
    LYNIS_SCORE=$(grep -E 'Hardening index' /var/log/lynis-hardening-report.txt | awk -F: '{print $2}' | tr -d ' ' || echo "Checked")
    log_success "Lynis audit complete! Hardening Index: ${C_BOLD}${LYNIS_SCORE}${C_RESET} (Report: /var/log/lynis-hardening-report.txt)"
  fi
fi

# ==================================================================
# PHASE 11 — Real-Time SSH Login Alerts (Telegram & Webhook)
# ==================================================================
echo ""
log_step "Fase 11 — Alertas de Login SSH em Tempo Real (PAM)"
log_info "Objetivo: Disparar notificações instantâneas a cada login SSH no servidor (Opcional)."

if ([ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]) || [ -n "$WEBHOOK_URL" ]; then
  PHASE11_ALREADY_CONFIGURED=false
  if [ -f /usr/local/bin/ssh-login-alert.sh ] && [ -f /etc/pam.d/sshd ] && grep -q 'ssh-login-alert.sh' /etc/pam.d/sshd; then
    if [ -n "$TG_BOT_TOKEN" ] && grep -q "$TG_BOT_TOKEN" /usr/local/bin/ssh-login-alert.sh 2>/dev/null; then
      PHASE11_ALREADY_CONFIGURED=true
    elif [ -n "$WEBHOOK_URL" ] && grep -q "$WEBHOOK_URL" /usr/local/bin/ssh-login-alert.sh 2>/dev/null; then
      PHASE11_ALREADY_CONFIGURED=true
    fi
  fi

  if [ "$PHASE11_ALREADY_CONFIGURED" = true ]; then
    log_success "Fase 11: Alertas de login SSH (PAM) já estão configurados no padrão. Pulando..."
  else
    log_step "11. Configuring real-time SSH login notifications via PAM..."
    cat > /usr/local/bin/ssh-login-alert.sh <<'EOF'
#!/usr/bin/env bash
# Real-time SSH Login Notification Dispatcher for Telegram & Webhooks
set -euo pipefail

TG_BOT_TOKEN="__TG_BOT_TOKEN_PLACEHOLDER__"
TG_CHAT_ID="__TG_CHAT_ID_PLACEHOLDER__"
WEBHOOK_URL="__WEBHOOK_URL_PLACEHOLDER__"

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
  elif [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "none" ]; then
    # Generic Webhook JSON POST
    JSON_PAYLOAD=$(cat <<JSON
{"event":"ssh_login","server":"${HOST}","user":"${USER}","remote_ip":"${IP}","timestamp":"${DATE}"}
JSON
)
    curl -fsSL -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 &
  fi
fi
exit 0
EOF

    sed -i "s|__TG_BOT_TOKEN_PLACEHOLDER__|$TG_BOT_TOKEN|g" /usr/local/bin/ssh-login-alert.sh
    sed -i "s|__TG_CHAT_ID_PLACEHOLDER__|$TG_CHAT_ID|g" /usr/local/bin/ssh-login-alert.sh
    sed -i "s|__WEBHOOK_URL_PLACEHOLDER__|$WEBHOOK_URL|g" /usr/local/bin/ssh-login-alert.sh
    chmod 755 /usr/local/bin/ssh-login-alert.sh

    if [ -f /etc/pam.d/sshd ]; then
      [ -f /etc/pam.d/sshd.bak ] || cp /etc/pam.d/sshd /etc/pam.d/sshd.bak
      if ! grep -q 'ssh-login-alert.sh' /etc/pam.d/sshd; then
        echo "session optional pam_exec.so seteuid /usr/local/bin/ssh-login-alert.sh" >> /etc/pam.d/sshd
      fi
    fi

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      log_info "Testing Telegram bot connection..."
      TEST_MSG="🛡️ <b>VPS Hardening Alert Activated!</b>%0AServer: <code>$(hostname)</code>%0APort: <code>${SSH_PORT}</code>"
      curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=🛡️ VPS Hardening Alert Activated for $(hostname) on port ${SSH_PORT}" >/dev/null 2>&1 || true
      log_success "Telegram SSH login alert configured and connected to Chat ID: ${TG_CHAT_ID}."
    else
      log_success "PAM SSH login alert webhook configured."
    fi
  fi
else
  log_info "Fase 11: Alertas de login SSH não configurados (Fase opcional — se Telegram ou Webhook não forem informados, esta etapa não é ativada)."
fi

# ==================================================================
# POST-HARDENING VERIFICATION & AUDIT SUITE
# ==================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd || true)"

# Install verify-hardening globally to /usr/local/bin
if [ -f "$SCRIPT_DIR/verify.sh" ]; then
  cp "$SCRIPT_DIR/verify.sh" /usr/local/bin/verify-hardening
  chmod 755 /usr/local/bin/verify-hardening
elif [ ! -f /usr/local/bin/verify-hardening ]; then
  # Download if executed via pipe or standalone
  REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main}"
  curl -fsSL "${REPO_RAW_URL}/verify.sh" -o /usr/local/bin/verify-hardening 2>/dev/null || true
  chmod 755 /usr/local/bin/verify-hardening 2>/dev/null || true
fi

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
echo -e "    ${C_CYAN}ssh -p ${SSH_PORT} ${NOVO_USUARIO}@${DETECTED_IP}${C_RESET}"
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
  echo -e "    - SSH login alerts:    Não configurado (opcional — só é ativado se informado Telegram ou Webhook)"
fi
  if [ "$RUN_AUDIT" = true ]; then
    echo -e "    - Lynis audit complete (Hardening Index: ${C_GREEN}${LYNIS_SCORE}${C_RESET}, Report: /var/log/lynis-hardening-report.txt)"
  fi
  echo -e "    - Verification suite:  run anytime via '${C_CYAN}sudo verify-hardening${C_RESET}' or '${C_CYAN}sudo ./verify.sh${C_RESET}'"
echo ""
echo -e "  ${C_BOLD}Rollback Snapshot:${C_RESET}"
if [ -n "$ROLLBACK_SNAPSHOT_PATH" ]; then
  echo -e "    - Snapshot archive: ${C_CYAN}${ROLLBACK_SNAPSHOT_PATH}${C_RESET}"
  echo -e "    - Instant rollback: ${C_CYAN}sudo ./hardening.sh --rollback${C_RESET} or ${C_CYAN}sudo ./rollback.sh${C_RESET}"
fi
echo ""
echo -e "  ${C_BOLD}Backups Created:${C_RESET}"
echo -e "    - /etc/ssh/sshd_config.bak and /etc/ssh/sshd_config.d/*.conf.bak (SSH backups)"
if ([ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]) || [ -n "$WEBHOOK_URL" ]; then
  echo -e "    - /etc/pam.d/sshd.bak (PAM SSH backup)"
fi
echo -e "    - /home/*/.ssh/authorized_keys.disabled (disabled default provider keys)"
echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
