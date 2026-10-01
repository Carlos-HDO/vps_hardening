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
| **Take a snapshot / backup via your cloud control panel** beforehand | Provides instant rollback if critical network configurations fail. |
| If you lose SSH access, utilize the **cloud provider's web console (VNC / Serial)** | Contabo, DigitalOcean, Hetzner, Vultr, AWS, etc., provide browser-based rescue consoles. |

---

## Phase 1 — Base System

### 1.1 Update Package Repositories and System Packages

First command upon logging in as `root`:

```bash
apt update && apt upgrade -y
```

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
ssh -p 52211 operator@VPS_IP_ADDRESS
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
```

Apply immediately:

```bash
sysctl --system
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

## 🔧 Diagnostic Commands

```bash
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
```

---

## 🚨 Troubleshooting

| Issue | Likely Cause | Resolution |
| :--- | :--- | :--- |
| SSH port does not change | systemd socket activation active | Run `systemctl disable --now ssh.socket && systemctl restart ssh.service` |
| `ss` still shows port 22 in LISTEN | SSH service was not restarted | `systemctl restart ssh.service` |
| `Failed to access socket path` (Fail2ban) | Daemon socket initializing | Wait 2 seconds and rerun command |
| Locked out of VPS | Firewall rule or invalid key | Access VPS via Cloud Provider Web VNC Console |
| Banned by Fail2ban | Repeated failed authentications | `fail2ban-client set sshd unbanip <IP>` |
