# VPS Hardening Automation (`vps_hardening`)

Comprehensive, modular **VPS Security Hardening** automation tool designed for newly provisioned servers running **Ubuntu (20.04/22.04/24.04 LTS)** and **Debian (11/12+)**.

Applies battle-tested production security standards to transform a stock, internet-facing VPS into a resilient system protected against automated botnets, brute-force attacks, IP spoofing, and kernel-level memory exploitation.

---

## ⚡ Key Features (The 11 Security Phases)

- **Phase 1 — Base System & Clock Sync**: Non-interactive system updates (`apt-get upgrade`), baseline tool installation (`sudo`, `curl` for minimal Debian/Ubuntu images), timezone configuration, and NTP synchronization.
- **Phase 2 — Account Security & Cloud Provider Cleanup**: Creation of a dedicated non-root administrative account with verified `sudo` privileges, lockouts for pre-installed provider accounts (`ubuntu`, `debian`, `admin`), and disabling unverified `authorized_keys`.
- **Phase 3 — OpenSSH Hardening & Precedence Protection**: Complete disablement of password authentication (`PasswordAuthentication no`) and direct root login (`PermitRootLogin no`), sanitization of main `/etc/ssh/sshd_config` and drop-ins to guarantee OpenSSH first-match rule compliance, migration to a custom high port, resolution of Ubuntu 22.10/24.04 *systemd socket activation* (`ssh.socket`), and syntax verification prior to daemon reload.
- **Phase 4 — Restrictive Firewall (UFW)**: Default-deny incoming policy (`default deny incoming`), rate-limited SSH access (`ufw limit`) to mitigate scanning, and full IPv6 coverage.
- **Phase 5 — Brute-Force Mitigation (Fail2ban)**: Customized `/etc/fail2ban/jail.local` configuration featuring progressive ban escalation, systemd backend integration, and whitelisting for Docker containers and RFC1918 subnets.
- **Phase 6 — Kernel Hardening (sysctl) & Network Optimization**: Hypervisor detection (`systemd-detect-virt`) with automatic profile selection: full ASLR (`randomize_va_space = 2`), coredump protection (`fs.suid_dumpable = 0`), kernel pointer/dmesg restrictions, and **TCP BBR Congestion Control & Fair Queuing (FQ)** for reduced latency and accelerated network throughput under packet loss.
- **Phase 7 — Automated Security Upgrades**: Automated background security patching via `unattended-upgrades`.
- **Phase 8 — Filesystem & Memory Protection (CIS Benchmark)**: Hardening of shared memory `/dev/shm` with `nodev,nosuid,noexec` flags in `/etc/fstab` and absolute prohibition of process core memory dumps (`limits.d` and `systemd-coredump`).
- **Phase 9 — Kernel Modules Hardening**: Disabling legacy and attack-prone networking protocols (`dccp`, `sctp`, `rds`, `tipc`, `firewire-core`) in `/etc/modprobe.d/hardening.conf`.
- **Phase 10 — System Auditing & Intrusion Logging**: Automatic installation and initialization of the `auditd` kernel event auditor, with optional automated **Lynis** comprehensive security benchmark scan.
- **Phase 11 — Real-Time SSH Login Alerts**: Webhook notification engine integrated into PAM (`/etc/pam.d/sshd`) dispatching instant alerts (Discord / Telegram / Custom webhook) on successful SSH sessions.

---

## ⚠️ Golden Rules (Read Before Starting)

> [!CAUTION]
> 1. **Never close your active SSH session** during the hardening process! If an issue occurs, your open session is your lifeline to investigate and resolve it.
> 2. **Always verify the new connection in a NEW terminal** with your SSH key and credentials before ending the root session.
> 3. Create a **snapshot / backup** of the VPS in your cloud provider's control panel (Contabo, Hetzner, DigitalOcean, Linode, AWS, etc.) before running security scripts.

---

## 🚀 Execution Methods

### 1. Via Git Clone (Recommended)

Clone the repository directly onto the VPS and run:

```bash
git clone https://github.com/carlos-hdo/vps_hardening.git
cd vps_hardening
chmod +x hardening.sh
sudo ./hardening.sh
```

### 2. Direct Execution with Parameters

Pass username, public SSH key, and desired SSH port as arguments:

```bash
sudo ./hardening.sh operator "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... vps-access" 52211
```

Or using named flags with additional ports and Telegram alerts:

```bash
sudo ./hardening.sh -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -a 80,443 --tg-token "7123456:ABC..." --tg-chat "123456789" --audit -y
```

Or import your public key directly from GitHub (eliminates copy-paste errors):

```bash
sudo ./hardening.sh -u operator -k "gh:carlos-hdo" -p 52211 -a 80,443 -y
```

### 3. Via Direct Shell Pipe (Curl / Web Bootstrap)

To execute remotely without prior cloning:

```bash
# Interactive mode (safely reads inputs from /dev/tty even over pipes):
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash

# Non-interactive mode with arguments passed through bash:
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash -s -- operator "gh:carlos-hdo" 52211
```

---

## 🛠️ Command-Line Options

| Flag | Argument | Default | Description |
| :--- | :--- | :--- | :--- |
| `-u`, `--user` | `<username>` | `operator` | Name of the new administrative user |
| `-k`, `--key` | `"<ssh_key>"` | *(required)* | Authorized OpenSSH public key string, `gh:username`, or URL |
| `-p`, `--port` | `<number>` | `52211` | Custom SSH port (range `1024`–`65535`) |
| `-t`, `--timezone` | `<region>` | `America/Sao_Paulo` | System timezone (e.g. `UTC`, `America/New_York`) |
| `-a`, `--allow-ports` | `<ports>` | None | Additional incoming ports to allow in UFW (e.g. `80,443,51820/udp`) |
| `--dry-run` | None | `false` | Simulate actions without making actual changes to the system |
| `--rollback` | `[archive]` | Latest | Restore previous system configuration from pre-hardening snapshot |
| `--tg-token` | `<token>` | None | Telegram Bot Token from `@BotFather` for login alerts |
| `--tg-chat` | `<chat_id>` | None | Telegram Chat ID from `@userinfobot` for login alerts |
| `-w`, `--webhook` | `<url>` | None | Discord / Custom Webhook URL for real-time SSH alerts |
| `--audit`, `--lynis` | None | `false` | Run automated Lynis security baseline audit after hardening |
| `--no-verify` | None | `false` | Skip automatic post-hardening verification test suite |
| `-y`, `--yes` | None | `false` | Skip interactive plan confirmation prompt |
| `-h`, `--help` | None | — | Display help message and options |

---

## 📱 Configuração de Notificações via Telegram

### Como Obter suas Credenciais do Telegram (1 minuto)

1. **Criar o Bot**:
   * Abra o Telegram e procure por [@BotFather](https://t.me/BotFather).
   * Envie o comando `/newbot`.
   * Escolha um nome (ex: `VPS Guard`) e um usuário que termine em `bot` (ex: `meu_servidor_alerta_bot`).
   * O BotFather retornará o seu HTTP API Token (exemplo: `7123456789:ABCdefGhIJKlmNoPQRstuVWXyz`).

2. **Obter seu Chat ID**:
   * Abra o bot [@userinfobot](https://t.me/userinfobot) (ou [@getmyid_bot](https://t.me/getmyid_bot)) no Telegram e envie `/start`.
   * Copie o seu número de Id (exemplo: `123456789`).
   * **Importante**: Abra o chat do seu bot recém-criado e clique em **Start** (ou envie um `/start`) para autorizá-lo a enviar mensagens para você.

### 🚀 Como Usar no Script

#### Opção A — Pelo Wizard Interativo (Mais Fácil)
Ao rodar sem argumentos:
```bash
sudo ./hardening.sh
```
O assistente exibirá uma pergunta direta para ativar o Telegram:
```text
[*] Real-Time SSH Login Alerts:
? Configure instant Telegram alerts on SSH login? [y/N]: y
    → Telegram Bot Token (from @BotFather): 7123456789:ABCdefGhIJKlmNoPQRstuVWXyz
    → Telegram Chat ID (from @userinfobot): 123456789
```

#### Opção B — Via Linha de Comando (Flags)
Você pode passar o token e o chat ID diretamente:
```bash
sudo ./hardening.sh \
  -u operator \
  -k "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." \
  -p 52211 \
  --tg-token "7123456789:ABCdefGhIJKlmNoPQRstuVWXyz" \
  --tg-chat "123456789" \
  -y
```

### 📩 O que você receberá no Telegram a cada Login SSH
Sempre que alguém logar na sua VPS com sucesso (seja você ou qualquer tentativa), o PAM dispara imediatamente a seguinte mensagem formatada:

```text
🚨 VPS SSH LOGIN ALERT
━━━━━━━━━━━━━━━━━━
🖥️ Server: vps-prod-01
👤 User: operator
🌐 Remote IP: 189.40.122.15
🕒 Date: 2026-10-01 18:27:00 -03
━━━━━━━━━━━━━━━━━━
⚠️ If this was not you, verify active sessions immediately!
```

---

## 🛠️ Usabilidade e Flexibilidade Operacional

### 🌐 Liberação de Portas Adicionais (`-a` / `--allow-ports`)
Por padrão, o UFW fecha todas as conexões de entrada e permite apenas o SSH customizado. Se a VPS já executa serviços em produção (Nginx, Caddy, Docker, Wireguard, bancos de dados), você pode especificar quais portas manter abertas:

```bash
# Permite HTTP, HTTPS e VPN WireGuard (UDP) além da porta SSH
sudo ./hardening.sh -u operator -k "ssh-ed25519 ..." -p 52211 -a 80,443,51820/udp -y
```
> **No Wizard Interativo**: o script pergunta automaticamente `? Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp) [default: none]:`.

---

### 🔍 Modo Simulação / Dry-Run (`--dry-run`)
Permite ao sysadmin inspecionar detalhadamente cada ação, comando e arquivo que seria alterado ou criado sem tocar no sistema operacional:

```bash
sudo ./hardening.sh --dry-run
# Ou combinando com seus parâmetros:
sudo ./hardening.sh -u operator -k "ssh-ed25519 ..." -p 52211 -a 80,443 --dry-run
```
O script exibirá o plano completo com avisos `[DRY-RUN] Would create user...`, `[DRY-RUN] Would configure UFW...` e sairá com status de sucesso (`exit 0`).

---

### ⏪ Mecanismo de Rollback Instantâneo (`rollback.sh` ou `--rollback`)
Antes de executar qualquer modificação no sistema, o script cria automaticamente um snapshot compactado dos diretórios críticos em `/var/backups/vps_hardening/hardening_backup_<timestamp>.tar.gz` e cria um atalho `latest.tar.gz`.

Se houver necessidade de restaurar o estado original:

```bash
# Método 1: Utilitário dedicado de rollback (restaura o snapshot mais recente)
sudo ./rollback.sh

# Método 2: Via hardening.sh
sudo ./hardening.sh --rollback

# Método 3: Restaurar um backup timestamped específico
sudo ./rollback.sh /var/backups/vps_hardening/hardening_backup_20261001_180000.tar.gz
```
O rollback restaura `/etc/ssh`, `/etc/ufw`, `/etc/fail2ban`, `/etc/sysctl.d`, `/etc/pam.d/sshd` e reativa os serviços para o estado anterior de forma transparente e segura.

---

## 🧪 Post-Installation Verification

Always verify from an **independent local terminal**:

```bash
# 1. Test SSH connectivity using your private key and custom port
ssh -p 52211 operator@VPS_IP_ADDRESS

# 2. Confirm sudo privileges
sudo whoami
# Expected output: root

# 3. Lock root account password (ONLY after steps 1 & 2 succeed)
sudo passwd -l root
```

### Automated Security Audit & Verification Suite

The verification suite runs automatically right after `hardening.sh` completes. You can also re-run it at any time to audit the security baseline of your VPS:

```bash
# Via installed system command:
sudo verify-hardening

# Or directly from the cloned repository:
sudo ./verify.sh

# Or with custom parameters:
sudo ./verify.sh --port 52211 --user operator
```

### Useful Diagnostics:

```bash
# Check active listening ports (sshd should listen on custom port, not 22)
ss -tunap | grep sshd

# Review firewall status and rules
sudo ufw status numbered

# Inspect fail2ban jail status
sudo fail2ban-client status sshd

# Unban an IP address if inadvertently locked out
sudo fail2ban-client set sshd unbanip YOUR_IP
```

---

## 📁 Repository Layout

```
vps_hardening/
├── .github/
│   └── workflows/
│       └── ci.yml                # Automated CI pipeline (ShellCheck + Multi-OS Docker matrix)
├── hardening.sh                  # Main hardening and automation script
├── verify.sh                     # Automated test & verification audit suite (Phases 1-11)
├── rollback.sh                   # Emergency rollback and system restore utility
├── quick-install.sh              # Lightweight bootstrap wrapper for curl / pipelines
├── GUIDE.md                      # Technical in-depth reference guide (Phases 1-11)
├── README.md                     # Documentation and usage guide
├── LICENSE                       # MIT License
└── configs/
    ├── 00-hardening.conf         # OpenSSH hardening template
    ├── jail.local                # Fail2ban configuration template
    ├── 99-hardening.conf         # Kernel sysctl parameters template (with TCP BBR)
    ├── hardening-modprobe.conf   # Obsolete kernel protocols blacklist template
    ├── 10-hardening-coredump.conf# Core dump prevention limits template
    └── ssh-login-alert.sh        # PAM SSH alert notification dispatcher template
```

---

## 📄 License

Distributed under the [MIT](LICENSE) License.
