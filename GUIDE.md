# VPS Security Hardening Guide — Ubuntu / Debian

> Production initial security baseline guide for newly provisioned, internet-facing VPS servers.  
> Verified on **Ubuntu 24.04 LTS (Noble)** — compatible with Ubuntu 20.04/22.04 LTS and Debian 11/12+.

---

## ⚠️ Golden Rules (Read Before Starting)

| Rule | Rationale |
| :--- | :--- |
| **Never terminate your current SSH session** while modifying SSH or firewall rules | If a syntax error or lockout occurs, your active session remains open to fix it. |
| **Always verify access from a NEW terminal window** before dropping old access | Confirms that key authentication, port configuration, and firewall rules truly work. |
| **Allow the custom SSH port in UFW BEFORE enabling the firewall** | Prevents accidentally locking yourself out of the machine. |
| **Allow the custom SSH port in the provider's firewall too** (Hetzner Cloud Firewall, AWS Security Group, DigitalOcean Cloud Firewall…) | UFW only controls the server; an external firewall still blocks the new port. |
| **Keep an automatic way back** while testing (`hardening.sh` arms a 10-minute auto-revert timer in interactive mode) | If the new login fails and you lose the session, the server reverts by itself. |
| **Take a snapshot / backup via your cloud control panel** beforehand | Provides instant rollback if critical network configurations fail. |
| If you lose SSH access, utilize the **cloud provider's web console (VNC / Serial)** | Contabo, DigitalOcean, Hetzner, Vultr, AWS, etc., provide browser-based rescue consoles. |

---

## Phase 1 — Base System

### 1.1 Update Package Repositories and System Packages

First command upon logging in as `root`:

```bash
apt update && apt install -y sudo curl tmux && apt upgrade -y
```

> 💡 **Debian Note**: Minimal Debian images (netinst, cloud templates) often lack `sudo` and `curl` out of the box. `tmux` keeps long-running work alive if the SSH session drops. Installing them upfront prevents script breaks when configuring non-root administrative users.


### 1.2 Configure Timezone and NTP Synchronization

Inaccurate timestamps complicate incident analysis and log auditing across distributed systems.

```bash
timedatectl set-timezone America/Sao_Paulo
timedatectl status
```

Verify that `System clock synchronized: yes` and `NTP service: active` are displayed.

---

## Phase 2 — User Accounts

### 2.1 Create Non-Root Administrative User

Operating directly as `root` carries high security risks. Create a dedicated user and grant `sudo` privileges:

```bash
adduser operator
usermod -aG sudo operator
```

### 2.2 Audit Pre-Existing Cloud Provider Accounts

Cloud providers (Contabo, DigitalOcean, AWS, etc.) frequently ship default accounts with sudo access (`ubuntu`, `debian`, `admin`). This creates unmonitored attack surfaces.

> 💡 **Discovery Tip**: Running a `systemctl` command without `sudo` triggers the **Polkit** prompt, which lists all administrative accounts recognized on the system.

```bash
# List all accounts in the sudo group
getent group sudo

# Check status of suspicious default accounts
passwd -S ubuntu
getent passwd ubuntu
```

Lock the default account (reversible, recommended):

```bash
passwd -l ubuntu                      # Lock account password
usermod -s /usr/sbin/nologin ubuntu   # Prevent interactive shell logins
```

Check and disable any pre-installed SSH keys:

```bash
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
  mv /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys.disabled
fi
```

Verify that the account is locked (`L` status):

```bash
passwd -S ubuntu
```

### 2.3 Lock Root Account Password

In addition to disabling SSH root login (Phase 3), lock the root password:

```bash
sudo passwd -l root
passwd -S root    # Should return "L"
```

---

## Phase 3 — OpenSSH Hardening

> ⚠️ **The sequence of this phase is critical.** Always test your key in a separate terminal BEFORE disabling password authentication.

### 3.1 Generate and Deploy SSH Key

**On your local workstation** (not on the VPS):

```bash
ssh-keygen -t ed25519 -C "vps-access"
ssh-copy-id operator@VPS_IP_ADDRESS
```

### 3.2 Hardening `sshd_config`

Configuration applied in `/etc/ssh/sshd_config.d/00-hardening.conf`:

```ini
Port 52211                    # High custom port to eliminate scanning noise
PermitRootLogin no            # Prohibit direct root logins
PasswordAuthentication no     # Enforce public-key authentication exclusively
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3                # Limit authentication attempts per connection
LoginGraceTime 20             # Time allowed to complete authentication (seconds)
AllowUsers operator           # Strict user whitelist
ClientAliveInterval 300
ClientAliveCountMax 2
```

**Why change the default port?**  
Port changing is not security by obscurity — port scanners like `nmap` can discover open ports quickly. The true value is **noise reduction**: it eliminates 95%+ of automated bot scans targeted at port 22, keeping your auth logs clean for real anomaly detection. Choose a port between 1024 and 65535, avoiding common alternatives like 2222.

> ⚠️ **OpenSSH Precedence Gotcha (First Match Wins)**:  
> OpenSSH parses configuration files using a *first-match* evaluation rule: the first directive encountered for any given parameter is the one applied. If `/etc/ssh/sshd_config` contains `Port 22` or `PermitRootLogin yes` before `Include /etc/ssh/sshd_config.d/*.conf`, your drop-in configuration would be silently overridden!  
> Always sanitize the primary `/etc/ssh/sshd_config` by commenting conflicting directives and ensuring `Include /etc/ssh/sshd_config.d/*.conf` is declared at the top of the file.


### 3.3 Ubuntu Socket Activation Gotcha (Ubuntu 22.10+)

**Symptom**: You changed `Port` in `sshd_config`, restarted `sshd`, but `ss -tunap` still shows port 22 listening.

**Cause**: Modern Ubuntu utilizes **systemd socket activation**. An independent `ssh.socket` unit binds to port 22 regardless of `sshd_config` settings.

**Solution (Recommended)** — Disable socket activation and revert to standard service management:

```bash
systemctl disable --now ssh.socket
systemctl enable --now ssh.service
systemctl restart ssh.service
```

### 3.4 Verification

Validate syntax:

```bash
sshd -t
```

Check listening sockets:

```bash
ss -tunap | grep sshd
```

Output should show **only** `0.0.0.0:52211` and `[::]:52211` in `LISTEN` state.

**Test from a separate local terminal:**

```bash
ssh -i ~/.ssh/id_ed25519 -p 52211 operator@VPS_IP_ADDRESS
```

---

## Phase 4 — Firewall (UFW)

> **Golden Rule**: Always open the custom SSH port BEFORE turning on the firewall.

### 4.1 Base Configuration

```bash
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw limit 52211/tcp            # LIMIT instead of ALLOW (built-in rate limiting)
ufw --force enable
```

**Why `limit` over `allow`?**  
`ufw limit` drops connections from IP addresses that initiate 6 or more connections within 30 seconds, acting as an instantaneous line of defense before Fail2ban triggers.

### 4.2 Docker and UFW Interactions

> ⚠️ **Warning**: Docker manipulates `iptables` directly and bypasses UFW rules by default!  
> If you expose container ports using `docker run -p 8080:8080`, that port is exposed to the entire internet despite UFW rules.
> 
> **Mitigations:**
> - Bind only to localhost: `-p 127.0.0.1:8080:8080` (proxy via Nginx/Caddy).
> - Use the `ufw-docker` utility.
> - Configure `"iptables": false` in `/etc/docker/daemon.json` with manual routing.

---

## Phase 5 — Fail2ban & Anti-Brute-Force

### 5.1 Installation & Configuration

```bash
apt install fail2ban tmux -y
```

Create `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
# Whitelist local hostnames, loopbacks, Docker bridge networks, and private subnets
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
port = 52211
filter = sshd
logpath = %(sshd_log)s
maxretry = 3
findtime = 300
bantime = 7200
```

Start and test:

```bash
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd
```

### 5.2 Unbanning an IP Address

If you accidentally trigger bans during testing:

```bash
fail2ban-client set sshd unbanip YOUR_IP
```

---

## Phase 6 — Kernel Hardening (sysctl)

Create `/etc/sysctl.d/99-hardening.conf`:

```ini
# Anti IP spoofing / source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP redirects (prevents MITM route poisoning)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log martian/impossible packets
net.ipv4.conf.all.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Ignore ICMP broadcast pings (anti-smurf)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Maximum ASLR (Address Space Layout Randomization)
kernel.randomize_va_space = 2

# Restrict kernel pointer exposure in /proc
kernel.kptr_restrict = 2

# Restrict dmesg kernel logging to root
kernel.dmesg_restrict = 1

# Disable core dumps for setuid binaries
fs.suid_dumpable = 0

# TCP BBR Congestion Control & Fair Queuing (FQ)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

> 🚀 **TCP BBR (Bottleneck Bandwidth and RTT)**:  
> Developed by Google, BBR dynamically computes real-time network throughput and round-trip times to manage packet delivery rather than relying solely on lost packets. Pairing `net.core.default_qdisc = fq` (Fair Queuing) with `bbr` drastically cuts connection latency, mitigates bufferbloat, and boosts throughput across lossy or cross-region connections without affecting security.

> 💡 **Container Environments (LXC / OpenVZ / Docker)**:  
> Shared-kernel containers share memory subsystems directly with the host machine. In these environments, applying host-level memory directives (`randomize_va_space`, `kptr_restrict`, `dmesg_restrict`) returns `Permission denied`. The automated script automatically detects container environments (`systemd-detect-virt`) and applies a container-optimized profile consisting of supported network stack hardening parameters.

Load module, persist across reboots, and apply immediately:

```bash
# Load TCP BBR kernel module and ensure persistence
modprobe tcp_bbr
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

# Reload all sysctl parameters
sysctl --system

# Verify active congestion control algorithm
sysctl net.ipv4.tcp_congestion_control
# Expected output: net.ipv4.tcp_congestion_control = bbr
```

---

## Phase 7 — Automated Security Upgrades

```bash
apt install unattended-upgrades apt-listchanges -y
cat <<'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades --now
```

Dry-run test:

```bash
unattended-upgrade --dry-run --debug
```

---

## Phase 8 — Filesystem & Shared Memory Protection (CIS Benchmark)

### 8.1 Shared Memory Hardening (`/dev/shm`)

Shared memory (`/dev/shm`) is a world-writable temporary RAM filesystem frequently targeted by threat actors to stage and execute malicious payloads without writing to disk.

Protect `/dev/shm` by adding or updating the mount entry in `/etc/fstab`:

```bash
# Add or update /dev/shm mount flags
echo "tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0" >> /etc/fstab
mount -o remount,nodev,nosuid,noexec /dev/shm
```

* `nodev`: Prevents device node creation.
* `nosuid`: Ignores set-user-identifier and set-group-identifier bits.
* `noexec`: Disallows execution of any binary or script stored in `/dev/shm`.

### 8.2 Disabling Core Dumps

Memory dumps from crashed processes can leak sensitive data (API tokens, database credentials, in-memory private keys) to disk.

Create `/etc/security/limits.d/10-hardening-coredump.conf`:

```ini
* hard core 0
* soft core 0
```

Disable core dumps in systemd via `/etc/systemd/coredump.conf.d/disable.conf`:

```ini
[Coredump]
Storage=none
ProcessSizeMax=0
```

Together with `fs.suid_dumpable = 0` in sysctl, this completely prohibits unprivileged core memory extraction.

---

## Phase 9 — Kernel Modules Hardening (Legacy Protocols)

Rarely utilized legacy networking protocols (e.g., DCCP, SCTP, RDS, TIPC) and legacy hardware drivers have historically been vectors for local kernel privilege escalation (LPE).

Create `/etc/modprobe.d/hardening.conf`:

```ini
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
install firewire-core /bin/true
```

Using `install <module> /bin/true` (the standard CIS Benchmark pattern) ensures the Linux kernel executes `/bin/true` instead of loading the module driver, preventing exploitation.

---

## Phase 10 — System Auditing & Intrusion Logging

### 10.1 System Auditing Daemon (`auditd`)

The `auditd` daemon tracks system security events, modifications to critical files (`/etc/passwd`, `/etc/sudoers`), and suspicious administrative executions:

```bash
apt install auditd -y
systemctl enable auditd --now
auditctl -s
```

### 10.2 Lynis System Security Audit

**Lynis** performs an automated, comprehensive audit across over 300 security controls, calculating an overall Hardening Index:

```bash
apt install lynis -y
lynis audit system --quick
```

Review the audit score and generated recommendations in `/var/log/lynis.log` and `/var/log/lynis-report.dat`.

---

## Phase 11 — Real-Time SSH Login Alerts (Telegram & Webhooks)

Receive immediate mobile notifications whenever an administrator or adversary logs in to the server via SSH.

### 11.1 Telegram Bot Setup (Recommended — Takes ~1 minute)

1. **Create the Telegram Bot**:
   * Open Telegram and search for `@BotFather`.
   * Send `/newbot`, enter a friendly name (e.g. `VPS Security Alert`) and a username ending in `bot` (e.g. `my_vps_guard_bot`).
   * Copy the **HTTP API Token** provided (e.g. `7123456789:ABCdefGhIJKlmNoPQRstuVWXyz`).

2. **Retrieve your Chat ID**:
   * Search for `@userinfobot` or `@getmyid_bot` in Telegram and send `/start`.
   * Copy your numeric **Id** (e.g. `123456789`).
   * Send a test `/start` message to your newly created bot to initialize the conversation.

3. **Verify via Curl (Optional)**:
   ```bash
   curl -s -X POST "https://api.telegram.org/bot<YOUR_TOKEN>/sendMessage" \
     -d "chat_id=<YOUR_CHAT_ID>" \
     -d "parse_mode=HTML" \
     --data-urlencode "text=🔔 <b>Test Notification</b> from VPS"
   ```

### 11.2 Automated Dispatcher (`/usr/local/bin/ssh-login-alert.sh`)

Keep the credentials out of the script: store them in a root-only config file. `printf %q` keeps characters such as `&` or `|` in webhook URLs intact:

```bash
install -d -m 700 /etc/vps-hardening
(umask 077 && printf 'TG_BOT_TOKEN=%q\nTG_CHAT_ID=%q\nWEBHOOK_URL=%q\n' \
  "YOUR_TELEGRAM_BOT_TOKEN" "YOUR_TELEGRAM_CHAT_ID" "" > /etc/vps-hardening/alert.conf)
chmod 600 /etc/vps-hardening/alert.conf
```

Install the dispatcher from [`configs/ssh-login-alert.sh`](configs/ssh-login-alert.sh) (the same file `hardening.sh` deploys). It reads `/etc/vps-hardening/alert.conf`, JSON-escapes the login details and sends Telegram, Discord or generic webhook notifications in the background:

```bash
install -m 700 -o root -g root configs/ssh-login-alert.sh /usr/local/bin/ssh-login-alert.sh
echo "session optional pam_exec.so seteuid /usr/local/bin/ssh-login-alert.sh" >> /etc/pam.d/sshd
```

> 💡 sshd runs the PAM session as root, so the dispatcher can read the `600` config file. Using `session optional` and running curl with a trailing `&` sends notifications asynchronously: a network outage or API error never blocks or delays a legitimate SSH login.

---

## ⏪ Rollback & Auto-Revert Safety Timer

On its first run, `hardening.sh` saves the original state in `/var/backups/vps_hardening/` (root-only): a `.tar.gz` with the configuration it touches, a `.created` list of files it adds, and a `.state` file with service, UFW, sysctl, `/dev/shm` and default-account states. Later runs keep that snapshot.

```bash
sudo hardening-rollback            # or: sudo ./rollback.sh / sudo ./hardening.sh --rollback
sudo hardening-rollback --yes      # non-interactive
```

In interactive runs a transient systemd timer (`vps-hardening-autorevert`) runs this rollback automatically 10 minutes after the end of the script unless you type `CONFIRM`. To inspect or cancel it manually:

```bash
systemctl list-timers vps-hardening-autorevert.timer
sudo systemctl stop vps-hardening-autorevert.timer
```

---

## 🔧 Diagnostic Commands

```bash
# Automated Security Verification Suite (All 11 Phases)
sudo verify-hardening
# or
sudo ./verify.sh

# Network listening services
ss -tunap

# Firewall status and rule numbers
sudo ufw status numbered

# Active Fail2ban jails and ban statistics
sudo fail2ban-client status
sudo fail2ban-client status sshd

# Active sessions and terminal origin
who

# Check OpenSSH configuration syntax
sshd -t

# Live authentication logs
journalctl -u ssh -f

# Verify /dev/shm mount permissions
mount | grep /dev/shm

# Check core dump limits
ulimit -c

# Auditd service status
systemctl status auditd
```

---

## 🚨 Troubleshooting

| Issue | Likely Cause | Resolution |
| :--- | :--- | :--- |
| SSH port does not change | systemd socket activation active | Run `systemctl disable --now ssh.socket && systemctl restart ssh.service` |
| `ss` still shows port 22 in LISTEN | SSH service was not restarted or superseded in main `sshd_config` | Comment out `Port 22` in `/etc/ssh/sshd_config` and `systemctl restart ssh.service` |
| `Failed to access socket path` (Fail2ban) | Daemon socket initializing | Wait 2 seconds and rerun command |
| Locked out of VPS | Firewall rule or invalid key | Access VPS via Cloud Provider Web VNC Console |
| Banned by Fail2ban | Repeated failed authentications | `fail2ban-client set sshd unbanip <IP>` |
| `sysctl: Permission denied` | Shared container VPS (LXC/OpenVZ) | Host manages ASLR/kptr; container profile skips host-restricted sysctl parameters |
| PAM webhook fails to send | Missing curl or invalid webhook URL | Verify outgoing HTTP connectivity: `curl -fsSL https://www.google.com` and check `/etc/vps-hardening/alert.conf` |
| `-y` run stops with "has no password" | Admin account has no sudo password and none can be asked | Pass `--password-hash "$(openssl passwd -6)"` |
| Server went back to port 22 on its own | Safety timer expired without `CONFIRM` | Fix the access problem, re-run `hardening.sh` and confirm after testing the new login |
| New SSH port unreachable but UFW allows it | Provider firewall / security group blocks it | Allow the port in the provider's control panel |


