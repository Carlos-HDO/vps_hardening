# VPS Hardening Automation (`vps_hardening`)

Comprehensive, modular **VPS Security Hardening** automation tool designed for newly provisioned servers running **Ubuntu (20.04/22.04/24.04 LTS)** and **Debian (11/12+)**.

Applies battle-tested production security standards to transform a stock, internet-facing VPS into a resilient system protected against automated botnets, brute-force attacks, IP spoofing, and kernel-level memory exploitation.

---

## ⚡ Key Features (The 7 Security Phases)

- **Phase 1 — Base System & Clock Sync**: Non-interactive system updates (`apt-get upgrade`), timezone configuration, and NTP synchronization.
- **Phase 2 — Account Security & Cloud Provider Cleanup**: Creation of a dedicated non-root administrative account with `sudo` privileges, lockouts for pre-installed provider accounts (`ubuntu`, `debian`, `admin`), and disabling unverified `authorized_keys`.
- **Phase 3 — OpenSSH Hardening & Socket Activation**: Complete disablement of password authentication (`PasswordAuthentication no`) and direct root login (`PermitRootLogin no`), migration to a custom high port, resolution of Ubuntu 22.10/24.04 *systemd socket activation* (`ssh.socket`), and syntax verification prior to daemon reload.
- **Phase 4 — Restrictive Firewall (UFW)**: Default-deny incoming policy (`default deny incoming`), rate-limited SSH access (`ufw limit`) to mitigate scanning, and full IPv6 coverage.
- **Phase 5 — Brute-Force Mitigation (Fail2ban)**: Customized `/etc/fail2ban/jail.local` configuration featuring progressive ban escalation, systemd backend integration, and whitelisting for Docker containers and RFC1918 subnets.
- **Phase 6 — Kernel Hardening (sysctl)**: Strict reverse path filtering (anti-spoofing), rejection of ICMP redirects (anti-MITM), SYN flood defense (`tcp_syncookies`), maximum ASLR (`randomize_va_space = 2`), and kernel pointer/dmesg restrictions (`kptr_restrict`, `dmesg_restrict`).
- **Phase 7 — Automated Security Upgrades**: Automated background security patching via `unattended-upgrades`.

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

Or using named flags:

```bash
sudo ./hardening.sh -u operator -k "ssh-ed25519 AAAAC3..." -p 52211 -y
```

### 3. Via Direct Shell Pipe (Curl / Web Bootstrap)

To execute remotely without prior cloning:

```bash
# Interactive mode (safely reads inputs from /dev/tty even over pipes):
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash

# Non-interactive mode with arguments passed through bash:
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash -s -- operator "ssh-ed25519 AAAAC3..." 52211
```

---

## 🛠️ Command-Line Options

| Flag | Argument | Default | Description |
| :--- | :--- | :--- | :--- |
| `-u`, `--user` | `<username>` | `operator` | Name of the new administrative user |
| `-k`, `--key` | `"<ssh_key>"` | *(required)* | Authorized OpenSSH public key (`ed25519` / `rsa` / `ecdsa`) |
| `-p`, `--port` | `<number>` | `52211` | Custom SSH port (range `1024`–`65535`) |
| `-t`, `--timezone` | `<region>` | `America/Sao_Paulo` | System timezone (e.g. `UTC`, `America/New_York`) |
| `-y`, `--yes` | None | `false` | Skip interactive plan confirmation prompt |
| `-h`, `--help` | None | — | Display help message and options |

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
├── hardening.sh           # Main hardening and automation script
├── quick-install.sh       # Lightweight bootstrap wrapper for curl / pipelines
├── GUIDE.md               # Technical in-depth reference guide (Phases 1-7)
├── README.md              # Documentation and usage guide
├── LICENSE                # MIT License
└── configs/
    ├── 00-hardening.conf  # OpenSSH hardening template
    ├── jail.local         # Fail2ban configuration template
    └── 99-hardening.conf  # Kernel sysctl parameters template
```

---

## 📄 License

Distributed under the [MIT](LICENSE) License.
