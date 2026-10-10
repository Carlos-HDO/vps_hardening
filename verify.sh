#!/usr/bin/env bash
# ==============================================================================
# VPS Hardening Verification & Test Suite
# Audits and validates all 11 security phases applied by vps_hardening.
#
# Usage:
#   sudo ./verify.sh [options]
#   sudo verify-hardening
#
# Options:
#   -p, --port <port>       Target SSH port to verify (auto-detected if omitted)
#   -u, --user <username>   Target admin user to verify (auto-detected if omitted)
#   --embedded              Accepted for compatibility (no effect)
#   -h, --help              Show this help message
# ==============================================================================

set -uo pipefail

VERSION="1.0.1"

# Terminal colors and formatting
C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_BOLD="\033[1m"
C_DIM="\033[2m"

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARN_TESTS=0

CUSTOM_PORT=""
CUSTOM_USER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      CUSTOM_PORT="$2"
      shift 2
      ;;
    -u|--user)
      CUSTOM_USER="$2"
      shift 2
      ;;
    --embedded)
      # Accepted for compatibility with older hardening.sh versions (no-op)
      shift
      ;;
    -V|--version)
      echo "vps_hardening verify ${VERSION}"
      exit 0
      ;;
    -h|--help)
      cat <<EOF
Usage: sudo $0 [options]

Options:
  -p, --port <port>       Target SSH port (default: auto-detected or 52211)
  -u, --user <username>   Target admin username (default: auto-detected)
  --embedded              Accepted for compatibility (no effect)
  -V, --version           Print the version and exit
  -h, --help              Display this help message
EOF
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# Result reporting functions
check_pass() {
  local name="$1"
  local detail="${2:-}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  PASSED_TESTS=$((PASSED_TESTS + 1))
  if [ -n "$detail" ]; then
    echo -e "  ${C_GREEN}[ PASS ]${C_RESET} ${name} ${C_DIM}(${detail})${C_RESET}"
  else
    echo -e "  ${C_GREEN}[ PASS ]${C_RESET} ${name}"
  fi
}

check_fail() {
  local name="$1"
  local detail="${2:-}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  FAILED_TESTS=$((FAILED_TESTS + 1))
  if [ -n "$detail" ]; then
    echo -e "  ${C_RED}[ FAIL ]${C_RESET} ${name} ${C_RED}--> ${detail}${C_RESET}"
  else
    echo -e "  ${C_RED}[ FAIL ]${C_RESET} ${name}"
  fi
}

check_warn() {
  local name="$1"
  local detail="${2:-}"
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
  WARN_TESTS=$((WARN_TESTS + 1))
  if [ -n "$detail" ]; then
    echo -e "  ${C_YELLOW}[ WARN ]${C_RESET} ${name} ${C_YELLOW}(${detail})${C_RESET}"
  else
    echo -e "  ${C_YELLOW}[ WARN ]${C_RESET} ${name}"
  fi
}

check_info() {
  local message="$1"
  echo -e "  ${C_BLUE}[ INFO ]${C_RESET} ${message}"
}

print_header() {
  local phase="$1"
  local title="$2"
  echo ""
  echo -e "${C_BOLD}${C_CYAN}▶ ${phase}:${C_RESET} ${C_BOLD}${title}${C_RESET}"
}

# Root privilege warning
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo -e "${C_YELLOW}[!] WARNING: Running without root/sudo privileges. Some security checks (UFW, auditctl, /etc/shadow) may fail due to permissions.${C_RESET}"
fi

# Detect Virtualization
IS_CONTAINER=false
VIRT_ENV="bare-metal/kvm"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  detected_virt="$(systemd-detect-virt 2>/dev/null)" || detected_virt="none"
  if systemd-detect-virt --container >/dev/null 2>&1; then
    IS_CONTAINER=true
    VIRT_ENV="container ($detected_virt)"
  else
    VIRT_ENV="$detected_virt"
  fi
elif [ -f /.dockerenv ]; then
  IS_CONTAINER=true
  VIRT_ENV="container (docker)"
elif [ -d /proc/vz ]; then
  IS_CONTAINER=true
  VIRT_ENV="container (openvz)"
fi

# Auto-detect SSH Port
TARGET_PORT="$CUSTOM_PORT"
if [ -z "$TARGET_PORT" ]; then
  if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ]; then
    TARGET_PORT="$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config.d/00-hardening.conf | awk '{print $2}' | head -n 1 || true)"
  fi
  if [ -z "$TARGET_PORT" ]; then
    TARGET_PORT="$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
  fi
  if [ -z "$TARGET_PORT" ]; then
    TARGET_PORT="52211"
  fi
fi

# Auto-detect Admin User
TARGET_USER="$CUSTOM_USER"
if [ -z "$TARGET_USER" ]; then
  if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ]; then
    TARGET_USER="$(grep -E '^\s*AllowUsers\s+' /etc/ssh/sshd_config.d/00-hardening.conf | awk '{print $2}' | head -n 1 || true)"
  fi
  if [ -z "$TARGET_USER" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  fi
  if [ -z "$TARGET_USER" ]; then
    # Pick first non-system user in sudo group
    for u in $(getent group sudo 2>/dev/null | awk -F: '{print $4}' | tr ',' ' '); do
      if id -u "$u" &>/dev/null && [ "$(id -u "$u")" -ge 1000 ] && [ "$u" != "nobody" ]; then
        TARGET_USER="$u"
        break
      fi
    done
  fi
  if [ -z "$TARGET_USER" ]; then
    TARGET_USER="operator"
  fi
fi

echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}             VPS HARDENING SECURITY VERIFICATION SUITE  ${C_RESET}${C_DIM}v${VERSION}${C_RESET}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "  ${C_DIM}Host:${C_RESET} $(hostname) | ${C_DIM}OS:${C_RESET} $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || uname -s) | ${C_DIM}Virt:${C_RESET} ${VIRT_ENV}"
echo -e "  ${C_DIM}Target Port:${C_RESET} ${TARGET_PORT} | ${C_DIM}Admin User:${C_RESET} ${TARGET_USER}"
echo -e "${C_BOLD}------------------------------------------------------------------------------${C_RESET}"

# ==============================================================================
# PHASE 1 — Base System & Time Synchronization
# ==============================================================================
print_header "Phase 1" "Base System & Clock Synchronization"

# Check NTP status
if command -v timedatectl >/dev/null 2>&1; then
  NTP_ACTIVE="$(timedatectl status 2>/dev/null | grep -E 'NTP service: active|Network time on: yes|System clock synchronized: yes' || true)"
  if [ -n "$NTP_ACTIVE" ]; then
    check_pass "NTP Time Synchronization" "active"
  else
    check_warn "NTP Time Synchronization" "verify with 'timedatectl status'"
  fi
else
  check_warn "timedatectl utility" "not found"
fi

# Check baseline tools
if command -v sudo >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  check_pass "Baseline tools (sudo, curl)" "installed"
else
  check_fail "Baseline tools" "sudo or curl missing"
fi

# ==============================================================================
# PHASE 2 — User Accounts & Cloud Account Neutralization
# ==============================================================================
print_header "Phase 2" "User Accounts & Cloud Account Neutralization"

# Check administrative user
if id "$TARGET_USER" >/dev/null 2>&1; then
  if id -nG "$TARGET_USER" 2>/dev/null | grep -qw "sudo"; then
    check_pass "Admin user '${TARGET_USER}'" "member of sudo group"
  else
    check_fail "Admin user '${TARGET_USER}'" "not in sudo group"
  fi
else
  check_warn "Admin user '${TARGET_USER}'" "user does not exist"
fi

# Check neutralization of default provider accounts (ubuntu, debian, admin, centos)
DEFAULT_ACCOUNTS_SECURE=true
FOUND_DEFAULT_ACCOUNTS=0
for d_user in ubuntu debian admin centos; do
  if id "$d_user" >/dev/null 2>&1 && [ "$d_user" != "$TARGET_USER" ]; then
    FOUND_DEFAULT_ACCOUNTS=$((FOUND_DEFAULT_ACCOUNTS + 1))
    SHELL_VAL="$(getent passwd "$d_user" | cut -d: -f7)"
    PWD_STATUS="$(passwd -S "$d_user" 2>/dev/null | awk '{print $2}' || true)"
    
    if [ "$SHELL_VAL" = "/usr/sbin/nologin" ] || [ "$SHELL_VAL" = "/bin/false" ] || [ "$PWD_STATUS" = "L" ]; then
      : # properly locked
    else
      DEFAULT_ACCOUNTS_SECURE=false
      check_warn "Default account '${d_user}'" "shell: $SHELL_VAL, passwd status: $PWD_STATUS (should be locked)"
    fi

    if [ -f "/home/$d_user/.ssh/authorized_keys" ]; then
      DEFAULT_ACCOUNTS_SECURE=false
      check_fail "Default account '${d_user}'" "active authorized_keys found!"
    fi
  fi
done

if [ "$DEFAULT_ACCOUNTS_SECURE" = true ]; then
  if [ "$FOUND_DEFAULT_ACCOUNTS" -gt 0 ]; then
    check_pass "Cloud default accounts" "neutralized and disabled (${FOUND_DEFAULT_ACCOUNTS} detected)"
  else
    check_pass "Cloud default accounts" "no vulnerable default accounts found"
  fi
fi

# Check root password lock
ROOT_PWD_STATUS="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
if [ "$ROOT_PWD_STATUS" = "L" ]; then
  check_pass "Root password status" "locked (L)"
elif [ -n "$ROOT_PWD_STATUS" ]; then
  check_info "Root password status: '${ROOT_PWD_STATUS}' (can be locked via 'sudo passwd -l root' after testing)"
fi

# ==============================================================================
# PHASE 3 — OpenSSH Hardening
# ==============================================================================
print_header "Phase 3" "OpenSSH Hardening"

# Check syntax validity
if command -v sshd >/dev/null 2>&1; then
  SSHD_TEST_OUT="$(sshd -t 2>&1 || true)"
  if [ -z "$SSHD_TEST_OUT" ]; then
    check_pass "OpenSSH configuration syntax" "sshd -t valid"
  elif echo "$SSHD_TEST_OUT" | grep -qi "no hostkeys available" && [ "${EUID:-$(id -u)}" -ne 0 ]; then
    check_warn "OpenSSH configuration syntax" "run with sudo to test host keys (sshd: no hostkeys available)"
  else
    check_fail "OpenSSH configuration syntax" "sshd -t reports: ${SSHD_TEST_OUT}"
  fi

  # Check active configuration parameters via sshd -T
  SSHD_T="$(sshd -T 2>/dev/null || true)"
  if [ -n "$SSHD_T" ]; then
    # Password authentication
    if echo "$SSHD_T" | grep -qx "passwordauthentication no"; then
      check_pass "Password Authentication" "disabled (passwordauthentication no)"
    else
      check_fail "Password Authentication" "not disabled in sshd -T"
    fi

    # Root login
    if echo "$SSHD_T" | grep -qx "permitrootlogin no"; then
      check_pass "Root direct login" "disabled (permitrootlogin no)"
    else
      check_fail "Root direct login" "permitrootlogin is not 'no'"
    fi

    # Pubkey authentication
    if echo "$SSHD_T" | grep -qx "pubkeyauthentication yes"; then
      check_pass "Public Key Authentication" "enabled"
    else
      check_warn "Public Key Authentication" "pubkeyauthentication is not 'yes'"
    fi

    # Empty passwords
    if echo "$SSHD_T" | grep -qx "permitemptypasswords no"; then
      check_pass "Empty passwords" "disabled"
    else
      check_warn "Empty passwords" "not explicitly disabled"
    fi
  else
    # Fallback checking 00-hardening.conf directly
    if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ]; then
      if grep -qE '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config.d/00-hardening.conf; then
        check_pass "Password Authentication" "disabled in 00-hardening.conf"
      fi
      if grep -qE '^\s*PermitRootLogin\s+no' /etc/ssh/sshd_config.d/00-hardening.conf; then
        check_pass "Root direct login" "disabled in 00-hardening.conf"
      fi
    else
      check_warn "OpenSSH active parameters" "could not execute sshd -T (requires root)"
    fi
  fi
else
  check_fail "sshd binary" "not found"
fi

# Check listening port
if command -v ss >/dev/null 2>&1; then
  if ss -tlnp 2>/dev/null | grep -E "ssh" | grep -qE ":${TARGET_PORT}\b"; then
    check_pass "OpenSSH listening socket" "listening on port ${TARGET_PORT}"
  elif ss -tln 2>/dev/null | grep -qE ":${TARGET_PORT}\b"; then
    check_pass "OpenSSH listening socket" "port ${TARGET_PORT} open"
  else
    check_fail "OpenSSH listening socket" "not found listening on port ${TARGET_PORT}"
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -tln 2>/dev/null | grep -qE ":${TARGET_PORT}\b"; then
    check_pass "OpenSSH listening socket" "port ${TARGET_PORT} open"
  else
    check_fail "OpenSSH listening socket" "port ${TARGET_PORT} not listening"
  fi
fi

# Check systemd socket activation on Ubuntu
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  check_warn "Ubuntu ssh.socket activation" "ssh.socket is active (can conflict with custom port)"
else
  check_pass "Ubuntu ssh.socket activation" "disabled / resolved"
fi

# ==============================================================================
# PHASE 4 — UFW Stateful Firewall
# ==============================================================================
print_header "Phase 4" "UFW Stateful Firewall"

if command -v ufw >/dev/null 2>&1; then
  UFW_STATUS="$(ufw status 2>/dev/null || true)"
  if echo "$UFW_STATUS" | grep -q "Status: active"; then
    check_pass "UFW Status" "active"

    # Default deny policy
    UFW_VERBOSE="$(ufw status verbose 2>/dev/null || true)"
    if echo "$UFW_VERBOSE" | grep -qi "deny (incoming)"; then
      check_pass "Default incoming policy" "deny"
    else
      check_warn "Default incoming policy" "verify with 'ufw status verbose'"
    fi

    # SSH Port rule check (LIMIT or ALLOW)
    if echo "$UFW_STATUS" | grep -qE "${TARGET_PORT}(/tcp)?\s+(LIMIT|ALLOW)"; then
      ACTION_TYPE="$(echo "$UFW_STATUS" | grep -E "${TARGET_PORT}(/tcp)?" | awk '{print $2}' | head -n 1)"
      check_pass "UFW SSH rule (port ${TARGET_PORT})" "configured with ${ACTION_TYPE}"
    else
      check_fail "UFW SSH rule" "no active ALLOW/LIMIT rule for port ${TARGET_PORT}"
    fi

    # IPv6 enabled
    if [ -f /etc/default/ufw ] && grep -qE '^IPV6=yes' /etc/default/ufw; then
      check_pass "UFW IPv6 protection" "enabled"
    else
      check_warn "UFW IPv6 protection" "IPV6=yes not confirmed in /etc/default/ufw"
    fi
  else
    check_fail "UFW Status" "inactive or disabled"
  fi
else
  check_fail "UFW binary" "not installed"
fi

# ==============================================================================
# PHASE 5 — Fail2ban Intrusion Prevention
# ==============================================================================
print_header "Phase 5" "Fail2ban Intrusion Prevention"

if command -v fail2ban-client >/dev/null 2>&1; then
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    check_pass "Fail2ban service" "active (running)"
    
    # Check sshd jail
    if fail2ban-client status sshd >/dev/null 2>&1; then
      BANNED_COUNT="$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned:' | awk '{print $NF}' || echo '0')"
      check_pass "Fail2ban [sshd] jail" "active (currently banned: ${BANNED_COUNT})"
    else
      check_warn "Fail2ban [sshd] jail" "not responding or not loaded yet"
    fi

    # Check progressive ban escalation in config
    if [ -f /etc/fail2ban/jail.local ] && grep -qE 'bantime\.increment\s*=\s*true' /etc/fail2ban/jail.local; then
      check_pass "Fail2ban ban escalation" "bantime.increment enabled"
    fi
  else
    check_fail "Fail2ban service" "inactive / stopped"
  fi
else
  check_fail "fail2ban package" "not installed"
fi

# ==============================================================================
# PHASE 6 — Kernel Hardening (sysctl) & Network Optimization
# ==============================================================================
print_header "Phase 6" "Kernel sysctl & Network Optimization"

test_sysctl() {
  local param="$1"
  local expected="$2"
  local label="$3"
  local is_critical="${4:-true}"

  local val
  val="$(sysctl -n "$param" 2>/dev/null || true)"
  if [ "$val" = "$expected" ]; then
    check_pass "$label" "$param = $val"
  else
    if [ "$is_critical" = true ]; then
      check_fail "$label" "expected '$expected', current '$val'"
    else
      check_warn "$label" "current '$val' (expected '$expected')"
    fi
  fi
}

# Network security
test_sysctl "net.ipv4.tcp_syncookies" "1" "SYN Flood Protection"
test_sysctl "net.ipv4.conf.all.rp_filter" "1" "Reverse Path Filtering (Anti-Spoofing)"
test_sysctl "net.ipv4.conf.all.accept_source_route" "0" "Disable IP Source Routing"
test_sysctl "net.ipv4.conf.all.accept_redirects" "0" "Ignore ICMP Redirects (MITM prevention)"
test_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1" "Ignore Broadcast Ping (Anti-Smurf)"

# Memory & Kernel security (conditional on container vs VM)
if [ "$IS_CONTAINER" = false ]; then
  test_sysctl "kernel.randomize_va_space" "2" "ASLR Memory Randomization"
  test_sysctl "kernel.kptr_restrict" "2" "Kernel Pointer Restriction"
  test_sysctl "kernel.dmesg_restrict" "1" "dmesg Kernel Log Restriction"
  test_sysctl "fs.suid_dumpable" "0" "Setuid Core Dump Prevention"
else
  check_info "Container virtualization ($VIRT_ENV): Memory ASLR & kptr are managed by the host kernel."
  test_sysctl "fs.suid_dumpable" "0" "Setuid Core Dump Prevention" false
fi

# TCP BBR Congestion Control
BBR_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
if [ "$BBR_CC" = "bbr" ]; then
  check_pass "TCP BBR Congestion Control" "active"
else
  check_warn "TCP BBR Congestion Control" "current: '$BBR_CC' (requires kernel BBR support)"
fi

# ==============================================================================
# PHASE 7 — Automated Security Updates
# ==============================================================================
print_header "Phase 7" "Automated Security Updates"

if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  check_pass "unattended-upgrades configuration" "enabled (20auto-upgrades)"
else
  check_fail "unattended-upgrades configuration" "20auto-upgrades missing or disabled"
fi

if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null || systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
  check_pass "unattended-upgrades service" "active / enabled"
else
  check_warn "unattended-upgrades service" "service not reported active"
fi

# ==============================================================================
# PHASE 8 — Filesystem & Memory Protection (CIS Benchmark)
# ==============================================================================
print_header "Phase 8" "Filesystem & Memory Protection (CIS)"

# Shared memory /dev/shm mount flags
SHM_MOUNT="$(mount | grep -E '\s/dev/shm\s' || true)"
SHM_FSTAB="$(grep -E '\s/dev/shm\s' /etc/fstab 2>/dev/null || true)"

if echo "$SHM_MOUNT" | grep -q "nodev" && echo "$SHM_MOUNT" | grep -q "nosuid" && echo "$SHM_MOUNT" | grep -q "noexec"; then
  check_pass "Shared memory (/dev/shm)" "mounted with nodev, nosuid, noexec"
elif echo "$SHM_FSTAB" | grep -q "nodev" && echo "$SHM_FSTAB" | grep -q "nosuid" && echo "$SHM_FSTAB" | grep -q "noexec"; then
  check_pass "Shared memory (/dev/shm)" "configured in /etc/fstab (nodev, nosuid, noexec)"
else
  check_warn "Shared memory (/dev/shm)" "nodev, nosuid, noexec not fully applied in current mount"
fi

# Core dumps disabled
if [ -f /etc/security/limits.d/10-hardening-coredump.conf ] && grep -q '\* hard core 0' /etc/security/limits.d/10-hardening-coredump.conf; then
  check_pass "Process core dump limits" "hard core 0 in limits.d"
else
  check_warn "Process core dump limits" "10-hardening-coredump.conf missing"
fi

# ==============================================================================
# PHASE 9 — Kernel Modules Hardening (Legacy Protocol Blacklist)
# ==============================================================================
print_header "Phase 9" "Kernel Modules Hardening"

MODPROBE_FILE="/etc/modprobe.d/hardening.conf"
if [ -f "$MODPROBE_FILE" ]; then
  PROTO_COUNT=0
  for proto in dccp sctp rds tipc; do
    if grep -q "install $proto /bin/true" "$MODPROBE_FILE"; then
      PROTO_COUNT=$((PROTO_COUNT + 1))
    fi
  done
  if [ "$PROTO_COUNT" -ge 4 ]; then
    check_pass "Legacy network protocols disabled" "dccp, sctp, rds, tipc blacklisted"
  else
    check_warn "Legacy network protocols" "some protocols missing from $MODPROBE_FILE"
  fi
else
  check_fail "Modprobe blacklist" "$MODPROBE_FILE not found"
fi

# ==============================================================================
# PHASE 10 — System Auditing & Intrusion Logging
# ==============================================================================
print_header "Phase 10" "System Auditing & Intrusion Logging"

if systemctl is-active --quiet auditd 2>/dev/null; then
  check_pass "auditd system auditor" "active (running)"
else
  if command -v auditd >/dev/null 2>&1; then
    check_warn "auditd system auditor" "installed but not active"
  else
    check_fail "auditd system auditor" "not installed"
  fi
fi

if [ -f /var/log/lynis-hardening-report.txt ]; then
  SCORE="$(grep -E 'Hardening index' /var/log/lynis-hardening-report.txt 2>/dev/null | awk -F: '{print $2}' | tr -d ' ' || echo 'Checked')"
  check_pass "Lynis security audit report" "present (Index: ${SCORE})"
else
  check_info "Lynis security audit: not run yet (optional: run with 'sudo lynis audit system --quick')"
fi

# ==============================================================================
# PHASE 11 — Real-Time SSH Login Alerts (PAM)
# ==============================================================================
print_header "Phase 11" "Real-Time SSH Login Alerts"

PAM_CONFIGURED=false
if [ -f /etc/pam.d/sshd ] && grep -q 'ssh-login-alert.sh' /etc/pam.d/sshd; then
  PAM_CONFIGURED=true
fi

ALERT_SCRIPT="/usr/local/bin/ssh-login-alert.sh"
ALERT_CONF="/etc/vps-hardening/alert.conf"

# Returns 0 if KEY has a non-empty value in alert.conf (values are written with printf %q)
alert_conf_has() {
  grep -E "^$1=" "$ALERT_CONF" 2>/dev/null | grep -qvx "$1=''"
}

if [ -f "$ALERT_SCRIPT" ]; then
  if grep -qE '^(TG_BOT_TOKEN="[0-9]+:|WEBHOOK_URL="https?://)' "$ALERT_SCRIPT" 2>/dev/null; then
    check_fail "SSH alert credentials storage" "secrets embedded in ${ALERT_SCRIPT} — re-run hardening.sh to move them to ${ALERT_CONF}"
  elif [ ! -x "$ALERT_SCRIPT" ]; then
    check_warn "SSH Login Alerts" "${ALERT_SCRIPT} is not executable"
  elif [ "$PAM_CONFIGURED" = false ]; then
    check_warn "SSH Login Alerts" "script exists but PAM hook in /etc/pam.d/sshd is missing"
  elif [ ! -f "$ALERT_CONF" ]; then
    check_warn "SSH Login Alerts" "PAM hook active, but ${ALERT_CONF} is missing"
  else
    ALERT_CONF_PERM="$(stat -c '%a %U' "$ALERT_CONF" 2>/dev/null || true)"
    if [ "$ALERT_CONF_PERM" != "600 root" ]; then
      check_fail "SSH alert credentials storage" "${ALERT_CONF} must be mode 600 owned by root (found: ${ALERT_CONF_PERM:-unknown})"
    elif alert_conf_has TG_BOT_TOKEN && alert_conf_has TG_CHAT_ID; then
      check_pass "SSH Login Alerts" "Telegram Bot dispatch active via PAM"
    elif alert_conf_has WEBHOOK_URL; then
      check_pass "SSH Login Alerts" "Discord / Custom Webhook active via PAM"
    else
      check_warn "SSH Login Alerts" "PAM hook active, but no notification channel in ${ALERT_CONF}"
    fi
  fi
else
  check_info "SSH Login Alerts: Not configured (Optional phase — inactive if Telegram or Webhook was not provided)"
fi

# ==============================================================================
# FINAL SCORE & SUMMARY
# ==============================================================================
PERCENTAGE=0
if [ "$TOTAL_TESTS" -gt 0 ]; then
  PERCENTAGE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
fi

echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_BOLD}                      VERIFICATION SUMMARY & AUDIT SCORE                      ${C_RESET}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "  Total Tests Audited : ${C_BOLD}${TOTAL_TESTS}${C_RESET}"
echo -e "  Tests Passed        : ${C_GREEN}${C_BOLD}${PASSED_TESTS}${C_RESET}"
echo -e "  Warnings            : ${C_YELLOW}${C_BOLD}${WARN_TESTS}${C_RESET}"
echo -e "  Failures            : ${C_RED}${C_BOLD}${FAILED_TESTS}${C_RESET}"
echo -e "  Security Score      : ${C_BOLD}${PERCENTAGE}%${C_RESET}"
echo -e "${C_BOLD}------------------------------------------------------------------------------${C_RESET}"

if [ "$FAILED_TESTS" -eq 0 ]; then
  echo -e "  ${C_GREEN}${C_BOLD}✔ RESULT: PASS — VPS is hardened and compliant with production baseline!${C_RESET}"
  EXIT_CODE=0
else
  echo -e "  ${C_RED}${C_BOLD}✖ RESULT: ATTENTION NEEDED — One or more critical security checks failed.${C_RESET}"
  EXIT_CODE=1
fi
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo ""

exit "$EXIT_CODE"
