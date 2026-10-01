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
  -y, --yes                   Skip interactive confirmation prompt
  -h, --help                  Display this help message

Examples:
  sudo $0 operator "ssh-ed25519 AAAAC3... vps-access" 52211
  sudo $0 -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -y
  sudo $0                     # Interactive wizard mode
EOF
    exit 0
  fi
done

# ------------------------------------------------------------------
# Root Privilege Check
# ------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_error "This script must be executed as root (use sudo)."
  echo "Example: sudo $0"
  exit 1
fi

# ------------------------------------------------------------------
# Default Configuration Variables
# ------------------------------------------------------------------
NOVO_USUARIO="${HARDENING_USER:-}"
CHAVE_SSH="${HARDENING_SSH_KEY:-}"
SSH_PORT="${HARDENING_SSH_PORT:-52211}"
TIMEZONE="${HARDENING_TIMEZONE:-America/Sao_Paulo}"
ASSUME_YES=false

show_help() {
  cat <<EOF
Usage: sudo $0 [options] or sudo $0 <user> "<ssh_key>" [port] [timezone]

Options:
  -u, --user <username>       Name of the new administrative user
  -k, --key "<ssh_key>"       Authorized public SSH key (ed25519, rsa, ecdsa)
  -p, --port <port>           Custom SSH port (1024-65535, default: 52211)
  -t, --timezone <tz>         System timezone (e.g., UTC, America/New_York, America/Sao_Paulo)
  -y, --yes                   Skip interactive confirmation prompt
  -h, --help                  Display this help message

Examples:
  sudo $0 operator "ssh-ed25519 AAAAC3... vps-access" 52211
  sudo $0 -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -y
  sudo $0                     # Interactive wizard mode
EOF
  exit 0
}

# ------------------------------------------------------------------
# Parameter Processing (Flags or Positional Arguments)
# ------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  if [[ "$1" == "-"* ]]; then
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -u|--user)     NOVO_USUARIO="$2"; shift 2 ;;
        -k|--key)      CHAVE_SSH="$2"; shift 2 ;;
        -p|--port)     SSH_PORT="$2"; shift 2 ;;
        -t|--timezone) TIMEZONE="$2"; shift 2 ;;
        -y|--yes)      ASSUME_YES=true; shift 1 ;;
        -h|--help)     show_help ;;
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
    log_info "Paste your SSH Public Key below (e.g., ssh-ed25519 AAAAC3...):"
    read_input "${C_YELLOW}?${C_RESET} SSH Public Key: " CHAVE_SSH ""
    if [ -z "$CHAVE_SSH" ]; then
      log_warn "An SSH public key is required to prevent server lockout!"
    fi
  done

  read_input "${C_YELLOW}?${C_RESET} Custom SSH Port [${SSH_PORT}]: " INPUT_PORT "$SSH_PORT"
  SSH_PORT="$INPUT_PORT"

  read_input "${C_YELLOW}?${C_RESET} Server Timezone [${TIMEZONE}]: " INPUT_TZ "$TIMEZONE"
  TIMEZONE="$INPUT_TZ"
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

# 2. SSH key validation
# Strip unwanted carriage returns or surrounding whitespace
CHAVE_SSH="$(echo "$CHAVE_SSH" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if ! echo "$CHAVE_SSH" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp[0-9]+@openssh.com) [A-Za-z0-9+/=]+'; then
  log_error "The SSH public key does not appear to be in a valid OpenSSH format."
  echo "    Expected format: ssh-ed25519 AAAAC3NzaC1... comment"
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
echo -e "  Timezone:          ${C_GREEN}${TIMEZONE}${C_RESET}"
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

echo ""
log_info "Starting hardening process..."

# ==================================================================
# PHASE 1 — Base System
# ==================================================================
log_step "1.1 Updating package repositories and system packages..."
apt-get update -qq
apt-get upgrade -y -qq

log_step "1.2 Configuring Timezone ($TIMEZONE) and NTP synchronization..."
if timedatectl list-timezones | grep -qx "$TIMEZONE"; then
  timedatectl set-timezone "$TIMEZONE"
else
  log_warn "Timezone '$TIMEZONE' not found on system. Keeping current timezone."
fi
timedatectl set-ntp true 2>/dev/null || true
log_success "Base system updated and system clock synchronized."

# ==================================================================
# PHASE 2 — User Accounts
# ==================================================================
log_step "2.1 Creating or configuring user '${NOVO_USUARIO}'..."
if id "$NOVO_USUARIO" &>/dev/null; then
  log_info "User '${NOVO_USUARIO}' already exists, ensuring sudo group membership."
else
  useradd -m -s /bin/bash "$NOVO_USUARIO"
  log_success "User '${NOVO_USUARIO}' created successfully."
fi
usermod -aG sudo "$NOVO_USUARIO"

# Set password if account is locked or has no password (required for sudo)
PASSWD_STATUS=$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")
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

# ==================================================================
# PHASE 3 — SSH Hardening
# ==================================================================
log_step "3.1 Installing authorized SSH key for '${NOVO_USUARIO}'..."
USER_HOME=$(getent passwd "$NOVO_USUARIO" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"
if ! grep -qxF "$CHAVE_SSH" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "$CHAVE_SSH" >> "$USER_HOME/.ssh/authorized_keys"
fi
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NOVO_USUARIO":"$NOVO_USUARIO" "$USER_HOME/.ssh"
log_success "Authorized SSH key installed in $USER_HOME/.ssh/authorized_keys."

log_step "3.2 Neutralizing conflicting override files in /etc/ssh/sshd_config.d/..."
if [ -d /etc/ssh/sshd_config.d ]; then
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "00-hardening.conf" ] && continue
    if grep -qE '^\s*(PasswordAuthentication|PermitRootLogin|Port)\b' "$f"; then
      cp "$f" "${f}.bak"
      sed -i -E 's/^\s*(PasswordAuthentication|PermitRootLogin|Port)\b/#&/' "$f"
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

# ==================================================================
# PHASE 4 — Firewall (UFW)
# ==================================================================
log_step "4. Configuring UFW Firewall..."
apt-get install -y -qq ufw

# Ensure IPv6 support is enabled
if [ -f /etc/default/ufw ]; then
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Allow SSH with rate-limiting prior to enabling firewall
ufw limit "$SSH_PORT"/tcp comment 'SSH Hardened Port' >/dev/null

# Force-enable UFW non-interactively
ufw --force enable >/dev/null
log_success "UFW active with restrictive default-deny policy and rate-limiting on port $SSH_PORT."

# ==================================================================
# PHASE 5 — Fail2ban & Brute Force Protection
# ==================================================================
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

# ==================================================================
# PHASE 6 — Kernel Hardening (sysctl)
# ==================================================================
log_step "6. Applying kernel security parameters (sysctl)..."
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
EOF

sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1 || true
log_success "Kernel hardening parameters applied successfully."

# ==================================================================
# PHASE 7 — Automatic Security Updates
# ==================================================================
log_step "7. Configuring unattended-upgrades..."
apt-get install -y -qq unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades --now >/dev/null 2>&1 || true
log_success "Automatic security upgrades enabled."

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
echo -e "  ${C_BOLD}Backups Created:${C_RESET}"
echo -e "    - /etc/ssh/sshd_config.d/*.conf.bak (modified configuration files)"
echo -e "    - /home/*/.ssh/authorized_keys.disabled (disabled default provider keys)"
echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
