# VPS Hardening Automation (`vps_hardening`)

Comprehensive, modular **VPS Security Hardening** automation tool designed for newly provisioned servers running **Ubuntu (20.04/22.04/24.04 LTS)** and **Debian (11/12+)**.

Applies battle-tested production security standards to transform a stock, internet-facing VPS into a resilient system protected against automated botnets, brute-force attacks, IP spoofing, and kernel-level memory exploitation.

---

## ⚡ Key Features (The 11 Security Phases)

- **Phase 1 — Base System & Clock Sync**: Non-interactive system updates (`apt-get upgrade`, skippable with `--skip-upgrade`), baseline tool installation (`sudo`, `curl`, `tmux` for minimal Debian/Ubuntu images), timezone configuration, and NTP synchronization.
- **Phase 2 — Account Security & Cloud Provider Cleanup**: Creation of a dedicated non-root administrative account with verified `sudo` privileges, lockouts for pre-installed provider accounts (`ubuntu`, `debian`, `admin`), and disabling unverified `authorized_keys`.
- **Phase 3 — OpenSSH Hardening & Precedence Protection**: Complete disablement of password authentication (`PasswordAuthentication no`) and direct root login (`PermitRootLogin no`), sanitization of main `/etc/ssh/sshd_config` and drop-ins to guarantee OpenSSH first-match rule compliance, migration to a custom high port, resolution of Ubuntu 22.10/24.04 *systemd socket activation* (`ssh.socket`), and syntax verification prior to daemon reload.
- **Phase 4 — Restrictive Firewall (UFW)**: Default-deny incoming policy (`default deny incoming`), rate-limited SSH access (`ufw limit`) to mitigate scanning, and full IPv6 coverage.
- **Phase 5 — Brute-Force Mitigation (Fail2ban)**: Customized `/etc/fail2ban/jail.local` configuration featuring progressive ban escalation, systemd backend integration, and whitelisting for Docker containers and RFC1918 subnets.
- **Phase 6 — Kernel Hardening (sysctl) & Network Optimization**: Hypervisor detection (`systemd-detect-virt`) with automatic profile selection: full ASLR (`randomize_va_space = 2`), coredump protection (`fs.suid_dumpable = 0`), kernel pointer/dmesg restrictions, and **TCP BBR Congestion Control & Fair Queuing (FQ)** for reduced latency and accelerated network throughput under packet loss.
- **Phase 7 — Automated Security Upgrades**: Automated background security patching via `unattended-upgrades`.
- **Phase 8 — Filesystem & Memory Protection (CIS Benchmark)**: Hardening of shared memory `/dev/shm` with `nodev,nosuid,noexec` flags in `/etc/fstab` and absolute prohibition of process core memory dumps (`limits.d` and `systemd-coredump`).
- **Phase 9 — Kernel Modules Hardening**: Disabling legacy and attack-prone networking protocols (`dccp`, `sctp`, `rds`, `tipc`, `firewire-core`) in `/etc/modprobe.d/hardening.conf`.
- **Phase 10 — System Auditing & Intrusion Logging**: Automatic installation and initialization of the `auditd` kernel event auditor, with optional automated **Lynis** comprehensive security benchmark scan.
- **Phase 11 — Real-Time SSH Login Alerts**: Webhook notification engine integrated into PAM (`/etc/pam.d/sshd`) dispatching instant alerts (Discord / Telegram / Custom webhook) on successful SSH sessions. Credentials are kept in a root-only file (`/etc/vps-hardening/alert.conf`, mode `600`).

Every run also takes a **first-run rollback snapshot**, can arm an **auto-revert safety timer** while you test the new SSH login, and finishes with an automated **verification suite**.

---

## ⚠️ Golden Rules (Read Before Starting)

> [!CAUTION]
> 1. **Never close your active SSH session** during the hardening process! If an issue occurs, your open session is your lifeline to investigate and resolve it.
> 2. **Always verify the new connection in a NEW terminal** with your SSH key and credentials before ending the root session.
> 3. Create a **snapshot / backup** of the VPS in your cloud provider's control panel (Contabo, Hetzner, DigitalOcean, Linode, AWS, etc.) before running security scripts.
> 4. If your provider has its **own firewall** (Hetzner Cloud Firewall, AWS Security Group, DigitalOcean Cloud Firewall, etc.), allow the new SSH port (default `52211/tcp`) there **before** running the script. UFW cannot open ports in the provider's firewall.
> 5. In interactive runs, the **safety timer** rolls everything back automatically after 10 minutes unless you type `CONFIRM` once the new login works. Don't confirm before testing in a new terminal.

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

> [!IMPORTANT]
> With `-y` (or without a terminal, e.g. cloud-init), the script cannot ask for the admin user's sudo password. If the account has no password yet, pass a crypt hash with `--password-hash`; otherwise the run stops **before any change**:
>
> ```bash
> sudo ./hardening.sh -u operator -k "gh:carlos-hdo" --password-hash "$(openssl passwd -6)" -y
> ```

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
| `--password-hash` | `'<hash>'` | None | Crypt hash (`openssl passwd -6`) for the admin user's sudo password, applied when the account has none. Required with `-y` in that case |
| `--safety-timer` | None | on (interactive) | Arm the auto-revert timer even with `-y` |
| `--no-safety-timer` | None | off (`-y`) | Never arm the auto-revert timer |
| `--skip-upgrade` | None | `false` | Skip `apt-get upgrade` in Phase 1 (package lists are still refreshed) |
| `--dry-run` | None | `false` | Simulate actions without making actual changes to the system |
| `--rollback` | `[archive]` | Original snapshot | Restore the pre-hardening state (delegates to `rollback.sh`) |
| `--tg-token` | `<token>` | None | Telegram Bot Token from `@BotFather` for login alerts |
| `--tg-chat` | `<chat_id>` | None | Telegram Chat ID from `@userinfobot` for login alerts |
| `-w`, `--webhook` | `<url>` | None | Discord / Custom Webhook URL for real-time SSH alerts |
| `--audit`, `--lynis` | None | `false` | Run automated Lynis security baseline audit after hardening |
| `--no-verify` | None | `false` | Skip automatic post-hardening verification test suite |
| `-y`, `--yes` | None | `false` | Skip interactive plan confirmation prompt |
| `-h`, `--help` | None | — | Display help message and options |

Environment variables can replace most flags (useful for automation): `HARDENING_USER`, `HARDENING_SSH_KEY`, `HARDENING_SSH_PORT`, `HARDENING_TIMEZONE`, `HARDENING_ALLOW_PORTS`, `HARDENING_PASSWORD_HASH`, `HARDENING_TG_TOKEN`, `HARDENING_TG_CHAT_ID`, `HARDENING_WEBHOOK_URL`, `HARDENING_RUN_AUDIT`, `HARDENING_SKIP_UPGRADE`, `HARDENING_SAFETY_TIMER` (`true`/`false`) and `HARDENING_SAFETY_TIMER_MINUTES` (default `10`).

---

## 📱 Telegram Notification Setup

### Getting your Telegram credentials (1 minute)

1. **Create the bot**:
   * Open Telegram and search for [@BotFather](https://t.me/BotFather).
   * Send `/newbot`.
   * Pick a name (e.g. `VPS Guard`) and a username ending in `bot` (e.g. `my_server_alert_bot`).
   * BotFather replies with your HTTP API token (e.g. `7123456789:ABCdefGhIJKlmNoPQRstuVWXyz`).

2. **Get your Chat ID**:
   * Open [@userinfobot](https://t.me/userinfobot) (or [@getmyid_bot](https://t.me/getmyid_bot)) and send `/start`.
   * Copy your numeric Id (e.g. `123456789`).
   * **Important**: open the chat with your new bot and press **Start** (or send `/start`) so it is allowed to message you.

### 🚀 Using it with the script

#### Option A — Interactive wizard (easiest)
Run without arguments:
```bash
sudo ./hardening.sh
```
The wizard asks whether to enable Telegram:
```text
[*] Real-Time SSH Login Alerts (Telegram / Webhook):
? Configure instant Telegram alerts on SSH login? [y/N]: y
    → Telegram Bot Token (from @BotFather): 7123456789:ABCdefGhIJKlmNoPQRstuVWXyz
    → Telegram Chat ID (from @userinfobot): 123456789
```

#### Option B — Command-line flags
Pass the token and chat ID directly:
```bash
sudo ./hardening.sh \
  -u operator \
  -k "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..." \
  -p 52211 \
  --tg-token "7123456789:ABCdefGhIJKlmNoPQRstuVWXyz" \
  --tg-chat "123456789" \
  --password-hash "$(openssl passwd -6)" \
  -y
```

The token, chat ID and webhook URL are stored in `/etc/vps-hardening/alert.conf` (`root:root`, mode `600`). The dispatcher `/usr/local/bin/ssh-login-alert.sh` holds no secrets.

### 📩 What you receive on every SSH login
Whenever someone logs in successfully (you or anyone else), PAM immediately sends:

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

## 🛠️ Operational Flexibility

### 🌐 Allowing additional ports (`-a` / `--allow-ports`)
By default UFW blocks all incoming connections except the custom SSH port. If the VPS already runs production services (Nginx, Caddy, Docker, WireGuard, databases), list the ports to keep open:

```bash
# Allow HTTP, HTTPS and WireGuard (UDP) in addition to SSH
sudo ./hardening.sh -u operator -k "ssh-ed25519 ..." -p 52211 -a 80,443,51820/udp -y
```
> **Interactive wizard**: the script asks `? Additional incoming ports to allow in UFW (e.g. 80,443,51820/udp) [none]:`.

If UFW is **already active** when the script runs, the new SSH port is opened before sshd moves to it, so the current firewall never blocks the new port.

---

### 🔍 Dry-run mode (`--dry-run`)
Lists every action, file and setting a real run would apply, phase by phase, without touching the system (root is not required):

```bash
sudo ./hardening.sh --dry-run
# Or with your parameters:
sudo ./hardening.sh -u operator -k "ssh-ed25519 ..." -p 52211 -a 80,443 --dry-run
```
The output shows `[DRY-RUN] Would ...` lines for the snapshot, all 11 phases, the safety timer and the verification suite, then exits with status `0`.

---

### ⏱️ Auto-revert safety timer
Before restarting SSH, an interactive run arms a transient systemd timer (`vps-hardening-autorevert`) that runs `hardening-rollback --yes`. At the end of the run the timer is reset to **10 minutes** and the script waits:

```text
  ⏱️  SAFETY TIMER ACTIVE — the system will be rolled back automatically in 10 minute(s).
? Type CONFIRM to keep the changes (Enter = leave timer running):
```

1. Test the login in a **new terminal** (`ssh -i ~/.ssh/id_ed25519 -p 52211 operator@VPS_IP`).
2. If it works, type `CONFIRM`. If you lose access, do nothing: the server reverts to its original SSH configuration by itself.

You can also confirm later with `sudo systemctl stop vps-hardening-autorevert.timer`. The timer is **on by default in interactive runs** and **off with `-y`** (nobody is there to confirm). Use `--safety-timer` / `--no-safety-timer` to override, or `HARDENING_SAFETY_TIMER_MINUTES` to change the window.

---

### ⏪ Rollback (`hardening-rollback`, `rollback.sh` or `--rollback`)
On the **first run**, before any change, the script saves in `/var/backups/vps_hardening/` (root-only, mode `700`):

| File | Content |
| :--- | :--- |
| `hardening_backup_<timestamp>.tar.gz` | Original `/etc/ssh`, `/etc/pam.d/sshd`, `/etc/sysctl.d`, `/etc/fstab`, `/etc/ufw`, `/etc/fail2ban`, `/etc/security/limits.d`, `/etc/modprobe.d`, `/etc/modules-load.d`, systemd coredump drop-ins, alert files |
| `hardening_backup_<timestamp>.created` | Files and directories the run creates (deleted on rollback) |
| `hardening_backup_<timestamp>.state` | UFW status, ssh/ssh.socket/fail2ban/auditd/unattended-upgrades unit states, original sysctl values, `/dev/shm` options, default cloud accounts |
| `latest.tar.gz` | Link to the original snapshot |

Later runs **keep** this snapshot, so a rollback always returns to the state before the first hardening.

```bash
# Installed helper (available even when the script was piped from curl)
sudo hardening-rollback

# From the cloned repository
sudo ./rollback.sh
sudo ./hardening.sh --rollback

# Non-interactive, or a specific archive
sudo ./rollback.sh --yes /var/backups/vps_hardening/hardening_backup_20261001_180000.tar.gz
```

The rollback restores the archived files, deletes the files the hardening created (`00-hardening.conf`, `99-hardening.conf`, `jail.local`, the modprobe/limits/coredump drop-ins, alert files, …), restores the original sysctl values, `/dev/shm` options, default cloud accounts and service states, disables UFW if it was not active before, and only then restarts SSH (after `sshd -t` succeeds), including Ubuntu's `ssh.socket` activation.

It **keeps** the admin user and the packages installed by the hardening (ufw, fail2ban, auditd, unattended-upgrades, tmux, lynis). Snapshots created by older versions (without `.created`/`.state`) only restore files.

---

## 🧪 Post-Installation Verification

Always verify from an **independent local terminal**:

```bash
# 1. Test SSH connectivity using your private key and custom port
ssh -i ~/.ssh/id_ed25519 -p 52211 operator@VPS_IP_ADDRESS

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
│       └── ci.yml                # CI: ShellCheck, config drift, dry-run matrix, E2E on Ubuntu runners
├── hardening.sh                  # Main hardening and automation script
├── verify.sh                     # Automated test & verification audit suite (Phases 1-11)
├── rollback.sh                   # Rollback utility (installed as hardening-rollback)
├── quick-install.sh              # Lightweight bootstrap wrapper for curl / pipelines
├── GUIDE.md                      # Technical in-depth reference guide (Phases 1-11)
├── README.md                     # Documentation and usage guide
├── SECURITY.md                   # How to report vulnerabilities
├── LICENSE                       # MIT License
├── plan/
│   └── PLAN.md                   # Remediation plan and its status
├── tests/
│   └── check-config-drift.sh     # CI check: configs/ templates == copies embedded in hardening.sh
└── configs/                      # Reference templates for manual hardening (kept in sync by CI)
    ├── 00-hardening.conf         # OpenSSH hardening template
    ├── jail.local                # Fail2ban configuration template
    ├── 99-hardening.conf         # Kernel sysctl parameters template (with TCP BBR)
    ├── hardening-modprobe.conf   # Obsolete kernel protocols blacklist template
    ├── 10-hardening-coredump.conf# Core dump prevention limits template
    └── ssh-login-alert.sh        # PAM SSH alert dispatcher (reads /etc/vps-hardening/alert.conf)
```

---

## 📄 License

Distributed under the [MIT](LICENSE) License.
