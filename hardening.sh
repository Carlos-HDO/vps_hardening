#!/usr/bin/env bash
#
# ==============================================================================
# VPS Hardening Automation Tool
# Compatível com Ubuntu 20.04/22.04/24.04 LTS e Debian 11/12+
#
# Modos de uso:
#   1) Interativo (execução direta ou via curl/wget | bash):
#      sudo ./hardening.sh
#      curl -fsSL <URL>/hardening.sh | sudo bash
#
#   2) Argumentos posicionais:
#      sudo ./hardening.sh <usuario> "<chave_publica_ssh>" [porta_ssh] [timezone]
#
#   3) Flags nomeadas:
#      sudo ./hardening.sh -u operador -k "ssh-ed25519 AAAA..." -p 52211 -y
# ==============================================================================

set -euo pipefail

# Variáveis de ambiente para evitar interrupções de pacotes
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Cores e formatação
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
log_error()   { echo -e "${C_RED}[-] ERRO:${C_RESET} $*" >&2; }

# Função auxiliar para leitura segura de terminal (mesmo se vindo de pipe `curl ... | bash`)
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
# Verificação rápida de ajuda (-h / --help)
# ------------------------------------------------------------------
for arg in "$@"; do
  if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
    cat <<EOF
Uso: sudo $0 [opções] ou sudo $0 <usuario> "<chave_ssh>" [porta] [timezone]

Opções:
  -u, --user <usuario>        Nome do novo usuário administrativo
  -k, --key "<chave_ssh>"     Chave pública SSH (ed25519, rsa, ecdsa)
  -p, --port <porta>          Porta SSH customizada (1024-65535, padrão: 52211)
  -t, --timezone <tz>         Fuso horário (ex: America/Sao_Paulo, America/Cuiaba)
  -y, --yes                   Pular confirmação interativa
  -h, --help                  Exibir esta ajuda

Exemplos:
  sudo $0 operador "ssh-ed25519 AAAAC3... vps-acesso" 52211
  sudo $0 -u operador -k "ssh-ed25519 AAAAC3..." -p 52211 -y
  sudo $0                     # Modo interativo com assistente
EOF
    exit 0
  fi
done

# ------------------------------------------------------------------
# Verificação de privilégios de root
# ------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  log_error "Este script precisa ser executado como root (use sudo)."
  echo "Exemplo: sudo $0"
  exit 1
fi

# ------------------------------------------------------------------
# Variáveis padrão
# ------------------------------------------------------------------
NOVO_USUARIO="${HARDENING_USER:-}"
CHAVE_SSH="${HARDENING_SSH_KEY:-}"
SSH_PORT="${HARDENING_SSH_PORT:-52211}"
TIMEZONE="${HARDENING_TIMEZONE:-America/Sao_Paulo}"
ASSUME_YES=false

show_help() {
  cat <<EOF
Uso: sudo $0 [opções] ou sudo $0 <usuario> "<chave_ssh>" [porta] [timezone]

Opções:
  -u, --user <usuario>        Nome do novo usuário administrativo
  -k, --key "<chave_ssh>"     Chave pública SSH (ed25519, rsa, ecdsa)
  -p, --port <porta>          Porta SSH customizada (1024-65535, padrão: 52211)
  -t, --timezone <tz>         Fuso horário (ex: America/Sao_Paulo, America/Cuiaba)
  -y, --yes                   Pular confirmação interativa
  -h, --help                  Exibir esta ajuda

Exemplos:
  sudo $0 operador "ssh-ed25519 AAAAC3... vps-acesso" 52211
  sudo $0 -u operador -k "ssh-ed25519 AAAAC3..." -p 52211 -y
  sudo $0                     # Modo interativo com assistente
EOF
  exit 0
}

# ------------------------------------------------------------------
# Processamento de parâmetros (Flags ou Posicionais)
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
        *) log_error "Parâmetro desconhecido: $1"; show_help ;;
      esac
    done
  else
    # Posicionais
    NOVO_USUARIO="${1:-}"
    CHAVE_SSH="${2:-}"
    SSH_PORT="${3:-52211}"
    TIMEZONE="${4:-America/Sao_Paulo}"
  fi
fi

# ------------------------------------------------------------------
# Modo Interativo (caso falte usuário ou chave SSH)
# ------------------------------------------------------------------
if [ -z "$NOVO_USUARIO" ] || [ -z "$CHAVE_SSH" ]; then
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}   ASSISTENTE DE CONFIGURAÇÃO DE HARDENING VPS${C_RESET}"
  echo -e "${C_BOLD}==========================================================${C_RESET}"
  echo ""

  if [ -z "$NOVO_USUARIO" ]; then
    read_input "${C_YELLOW}?${C_RESET} Nome do novo usuário administrativo [operador]: " NOVO_USUARIO "operador"
  fi

  while [ -z "$CHAVE_SSH" ]; do
    echo ""
    log_info "Cole abaixo a sua Chave Pública SSH (ex: ssh-ed25519 AAAAC3...):"
    read_input "${C_YELLOW}?${C_RESET} Chave SSH pública: " CHAVE_SSH ""
    if [ -z "$CHAVE_SSH" ]; then
      log_warn "A chave pública SSH é obrigatória para evitar lockout!"
    fi
  done

  read_input "${C_YELLOW}?${C_RESET} Porta SSH customizada [${SSH_PORT}]: " INPUT_PORT "$SSH_PORT"
  SSH_PORT="$INPUT_PORT"

  read_input "${C_YELLOW}?${C_RESET} Timezone do servidor [${TIMEZONE}]: " INPUT_TZ "$TIMEZONE"
  TIMEZONE="$INPUT_TZ"
fi

# ------------------------------------------------------------------
# Validação dos Dados
# ------------------------------------------------------------------
# 1. Validação do nome do usuário
if ! [[ "$NOVO_USUARIO" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  log_error "Nome de usuário inválido: '$NOVO_USUARIO'. Use letras minúsculas, números e sublinhados."
  exit 1
fi

if [ "$NOVO_USUARIO" = "root" ]; then
  log_error "O usuário novo não pode se chamar 'root'. Escolha outro nome (ex: operador)."
  exit 1
fi

# 2. Validação da chave SSH
# Limpar quebras de linha acidentais
CHAVE_SSH="$(echo "$CHAVE_SSH" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

if ! echo "$CHAVE_SSH" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp[0-9]+@openssh.com) [A-Za-z0-9+/=]+'; then
  log_error "A chave pública SSH não parece ter um formato válido."
  echo "    Esperado algo como: ssh-ed25519 AAAAC3NzaC1... comentario"
  exit 1
fi

# 3. Validação da porta SSH
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
  log_error "Porta inválida: '$SSH_PORT'. Deve ser um número entre 1024 e 65535."
  exit 1
fi

# ------------------------------------------------------------------
# Confirmação do Plano
# ------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}--- Parâmetros do Hardening ---${C_RESET}"
echo -e "  Usuário novo:      ${C_GREEN}${NOVO_USUARIO}${C_RESET}"
echo -e "  Chave SSH pública: ${C_GREEN}${CHAVE_SSH:0:40}...${C_RESET}"
echo -e "  Nova Porta SSH:    ${C_GREEN}${SSH_PORT}${C_RESET}"
echo -e "  Timezone:          ${C_GREEN}${TIMEZONE}${C_RESET}"
echo -e "${C_BOLD}--------------------------------${C_RESET}"
echo ""

if [ "$ASSUME_YES" = false ]; then
  CONFIRM=""
  read_input "${C_YELLOW}?${C_RESET} Deseja prosseguir com a aplicação das regras de segurança? [S/n]: " CONFIRM "S"
  if [[ ! "$CONFIRM" =~ ^[SsYy]$ ]] && [ -n "$CONFIRM" ]; then
    log_warn "Operação cancelada pelo usuário."
    exit 0
  fi
fi

echo ""
log_info "Iniciando processo de hardening..."

# ==================================================================
# FASE 1 — Base do sistema
# ==================================================================
log_step "1.1 Atualizando repositórios e pacotes do sistema..."
apt-get update -qq
apt-get upgrade -y -qq

log_step "1.2 Configurando Timezone ($TIMEZONE) e sincronização NTP..."
if timedatectl list-timezones | grep -qx "$TIMEZONE"; then
  timedatectl set-timezone "$TIMEZONE"
else
  log_warn "Timezone '$TIMEZONE' não encontrado no sistema. Mantendo atual."
fi
timedatectl set-ntp true 2>/dev/null || true
log_success "Base do sistema atualizada e horário sincronizado."

# ==================================================================
# FASE 2 — Contas de Usuário
# ==================================================================
log_step "2.1 Criando ou ajustando o usuário '${NOVO_USUARIO}'..."
if id "$NOVO_USUARIO" &>/dev/null; then
  log_info "Usuário '${NOVO_USUARIO}' já existe, atualizando grupos."
else
  useradd -m -s /bin/bash "$NOVO_USUARIO"
  log_success "Usuário '${NOVO_USUARIO}' criado com sucesso."
fi
usermod -aG sudo "$NOVO_USUARIO"

# Definir senha se a conta estiver sem senha ou bloqueada (necessária para sudo)
PASSWD_STATUS=$(passwd -S "$NOVO_USUARIO" 2>/dev/null | awk '{print $2}' || echo "L")
if [[ "$PASSWD_STATUS" =~ ^(L|NP)$ ]]; then
  echo ""
  log_warn "ATENÇÃO: Defina a senha para o usuário '${NOVO_USUARIO}' (obrigatória para o comando 'sudo'):"
  if [ -c /dev/tty ]; then
    passwd "$NOVO_USUARIO" < /dev/tty
  else
    passwd "$NOVO_USUARIO"
  fi
  echo ""
fi

log_step "2.2 Neutralizando contas administrativas padrão do provedor..."
for u in ubuntu debian admin centos; do
  if id "$u" &>/dev/null && [ "$u" != "$NOVO_USUARIO" ]; then
    passwd -l "$u" >/dev/null 2>&1 || true
    usermod -s /usr/sbin/nologin "$u" 2>/dev/null || true
    if [ -f "/home/$u/.ssh/authorized_keys" ]; then
      mv "/home/$u/.ssh/authorized_keys" "/home/$u/.ssh/authorized_keys.disabled" 2>/dev/null || true
    fi
    log_info "Conta padrão '$u' neutralizada (chave movida para .disabled)."
  fi
done
log_success "Gerenciamento de contas concluído."

# ==================================================================
# FASE 3 — SSH Hardening
# ==================================================================
log_step "3.1 Instalando chave SSH autorizada para '${NOVO_USUARIO}'..."
USER_HOME=$(getent passwd "$NOVO_USUARIO" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"
if ! grep -qxF "$CHAVE_SSH" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
  echo "$CHAVE_SSH" >> "$USER_HOME/.ssh/authorized_keys"
fi
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NOVO_USUARIO":"$NOVO_USUARIO" "$USER_HOME/.ssh"
log_success "Chave SSH autorizada instalada em $USER_HOME/.ssh/authorized_keys."

log_step "3.2 Neutralizando arquivos conflitantes em /etc/ssh/sshd_config.d/..."
if [ -d /etc/ssh/sshd_config.d ]; then
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "00-hardening.conf" ] && continue
    if grep -qE '^\s*(PasswordAuthentication|PermitRootLogin|Port)\b' "$f"; then
      cp "$f" "${f}.bak"
      sed -i -E 's/^\s*(PasswordAuthentication|PermitRootLogin|Port)\b/#&/' "$f"
      log_info "Neutralizado arquivo de override: $f (backup em ${f}.bak)"
    fi
  done
fi

log_step "3.3 Aplicando configuração segura em /etc/ssh/sshd_config.d/00-hardening.conf..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# Gerado automaticamente pelo VPS Hardening Script
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

log_step "3.4 Validando sintaxe da configuração do SSH..."
if ! sshd -t; then
  log_error "A validação do sshd_config falhou! Abortando alteração de serviço para evitar lockout."
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  exit 1
fi
log_success "Sintaxe do SSH válida."

log_step "3.5 Resolvendo socket activation (Ubuntu 22.10+) e reiniciando SSH..."
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service

sleep 2
if ss -tlnp | grep -qE ":$SSH_PORT\b"; then
  log_success "Serviço SSH está ativo e escutando na porta $SSH_PORT."
else
  log_warn "Aviso: sshd pode não estar escutando na porta $SSH_PORT ainda. Verifique com 'ss -tunap | grep sshd'."
fi

# ==================================================================
# FASE 4 — Firewall (UFW)
# ==================================================================
log_step "4. Configurando Firewall UFW..."
apt-get install -y -qq ufw

# Garante suporte a IPv6
if [ -f /etc/default/ufw ]; then
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
fi

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Permite SSH com rate-limit antes de ligar o firewall
ufw limit "$SSH_PORT"/tcp comment 'SSH Hardened Port' >/dev/null

# Ativa o UFW de forma forçada e não interativa
ufw --force enable >/dev/null
log_success "UFW ativo com política restritiva e rate-limit na porta $SSH_PORT."

# ==================================================================
# FASE 5 — Fail2ban & Proteção contra Brute Force
# ==================================================================
log_step "5. Instalando e configurando fail2ban e tmux..."
apt-get install -y -qq fail2ban tmux

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Ignora redes locais, loopback e faixas de containers Docker comuns
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
  log_success "Fail2ban ativo com jail [sshd] na porta $SSH_PORT."
else
  log_warn "Fail2ban inicializado, mas jail sshd pode levar alguns instantes para responder."
fi

# ==================================================================
# FASE 6 — Kernel Hardening (sysctl)
# ==================================================================
log_step "6. Aplicando parâmetros de segurança no kernel (sysctl)..."
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Anti IP spoofing / source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignora redirects ICMP (evita MITM via rota falsa)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Reverse path filtering (anti spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Loga pacotes com endereços suspeitos
net.ipv4.conf.all.log_martians = 1

# Proteção contra SYN flood
net.ipv4.tcp_syncookies = 1

# Ignora pings broadcast (anti smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ASLR máximo (proteção contra exploits de buffer overflow)
kernel.randomize_va_space = 2

# Restringe ponteiros do kernel em /proc
kernel.kptr_restrict = 2

# Restringe mensagens de dmesg para usuários sem root
kernel.dmesg_restrict = 1
EOF

sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1 || true
log_success "Configurações de kernel aplicadas com sucesso."

# ==================================================================
# FASE 7 — Atualizações Automáticas de Segurança
# ==================================================================
log_step "7. Configurando unattended-upgrades..."
apt-get install -y -qq unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades --now >/dev/null 2>&1 || true
log_success "Atualizações de segurança automáticas ativadas."

# ==================================================================
# RESUMO FINAL E INSTRUÇÕES CRÍTICAS
# ==================================================================
IP_DETECTADO=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "IP_DA_VPS")

echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}                     ✔ HARDENING APLICADO COM SUCESSO!                        ${C_RESET}"
echo -e "${C_BOLD}==============================================================================${C_RESET}"
echo ""
echo -e "${C_RED}${C_BOLD}  ⚠️  IMPORTANTE: NÃO FECHE ESTE TERMINAL AINDA!${C_RESET}"
echo ""
echo -e "  Execute os passos abaixo em um ${C_BOLD}NOVO terminal${C_RESET} na sua máquina local:"
echo ""
echo -e "  ${C_BOLD}Passo 1:${C_RESET} Teste a nova conexão SSH com a sua chave:"
echo -e "    ${C_CYAN}ssh -p ${SSH_PORT} ${NOVO_USUARIO}@${IP_DETECTADO}${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Passo 2:${C_RESET} Confirme que o privilégio de sudo funciona com o novo usuário:"
echo -e "    ${C_CYAN}sudo whoami${C_RESET}      ${C_BLUE}# Deve retornar 'root'${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Passo 3:${C_RESET} SOMENTE após confirmar os passos 1 e 2, trave a senha da conta root:"
echo -e "    ${C_CYAN}sudo passwd -l root${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Backups gerados:${C_RESET}"
echo -e "    - /etc/ssh/sshd_config.d/*.conf.bak (arquivos modificados)"
echo -e "    - /home/*/.ssh/authorized_keys.disabled (contas padrão desabilitadas)"
echo ""
echo -e "${C_BOLD}==============================================================================${C_RESET}"
