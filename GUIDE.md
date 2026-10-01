# Hardening de VPS — Ubuntu / Debian

> Guia de configuração inicial de segurança para VPS nova exposta à internet.
> Testado em **Ubuntu 24.04 LTS (Noble)** — compatível com Debian 12+.

---

## ⚠️ Regras de Ouro (Ler antes de começar)

| Regra | Motivo |
| :--- | :--- |
| **Nunca feche a sessão SSH atual** ao mexer em SSH/firewall | Se algo quebrar, você ainda tem acesso para corrigir. |
| **Sempre teste em uma sessão NOVA** antes de remover o acesso antigo | Confirma que o novo caminho funciona de verdade. |
| **Libere a porta no firewall ANTES de ativá-lo** | Evita se trancar do lado de fora. |
| **Tire snapshot pelo painel do provedor** antes de começar | Rollback rápido se algo der muito errado. |
| Se perder o acesso SSH, use o **console web do provedor** | Contabo, DigitalOcean, Vultr, Hetzner, etc., têm console VNC. |

---

## Fase 1 — Base do Sistema

### 1.1 Atualizar pacotes
Primeira ação após o login inicial como `root`:
```bash
apt update && apt upgrade -y
```

### 1.2 Definir timezone e sincronização de horário
Logs com hora errada atrapalham investigações de incidentes.
```bash
timedatectl set-timezone America/Sao_Paulo
timedatectl status
```
Confirme que aparece `System clock synchronized: yes` e `NTP service: active`.

---

## Fase 2 — Contas de Usuário

### 2.1 Criar usuário sem privilégios de root
Operar direto como root é risco crítico. Crie um usuário comum e dê acesso ao `sudo`:
```bash
adduser operador
usermod -aG sudo operador
```

### 2.2 Auditar contas administrativas pré-existentes
Provedores cloud (Contabo, DigitalOcean, AWS…) costumam deixar uma conta padrão com sudo (`ubuntu`, `debian`, `admin`). É superfície de ataque não monitorada.

> 💡 **Como descobrir**: Se ao rodar um comando `systemctl` sem `sudo` aparecer o prompt do **Polkit**, ele lista as identidades administrativas do sistema.

```bash
# Ver todas as contas no grupo sudo
getent group sudo

# Checar estado da conta suspeita
passwd -S ubuntu
getent passwd ubuntu
```

Travar a conta (reversível, recomendado):
```bash
passwd -l ubuntu                      # trava a senha
usermod -s /usr/sbin/nologin ubuntu   # impede shell interativo
```

Verificar e mover chave SSH cadastrada nela:
```bash
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
  mv /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys.disabled
fi
```

### 2.3 Travar a conta root
Além de desabilitar o login SSH do root (Fase 3), trave a senha:
```bash
sudo passwd -l root
passwd -S root    # deve retornar "L"
```

---

## Fase 3 — SSH

> ⚠️ **A ordem desta fase é crítica.** Configure a chave e teste ANTES de desabilitar senha.

### 3.1 Gerar e enviar chave SSH
**Na sua máquina local**, não na VPS:
```bash
ssh-keygen -t ed25519 -C "vps-acesso"
ssh-copy-id operador@IP_DA_VPS
```

### 3.2 Hardening do `sshd_config`
Configuração aplicada em `/etc/ssh/sshd_config.d/00-hardening.conf`:
```ini
Port 52211                    # porta alta customizada
PermitRootLogin no            # bloqueia login direto do root
PasswordAuthentication no     # só autenticação por chave
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3                # tentativas por conexão
LoginGraceTime 20             # segundos pra autenticar
AllowUsers operador           # whitelist de usuários
ClientAliveInterval 300
ClientAliveCountMax 2
```

### 3.3 Socket Activation (Ubuntu 22.10+)
Ubuntu recente usa systemd socket activation (`ssh.socket`), que escuta na porta 22 ignorando a mudança de porta no `sshd_config`.

**Solução:**
```bash
systemctl disable --now ssh.socket
systemctl enable --now ssh.service
systemctl restart ssh.service
```

### 3.4 Validar
```bash
ss -tunap | grep sshd
```
Deve mostrar **apenas** `0.0.0.0:52211` e `[::]:52211`.

---

## Fase 4 — Firewall (UFW)

### 4.1 Configuração base
```bash
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw limit 52211/tcp            # LIMIT em vez de ALLOW (rate-limit)
ufw --force enable
```

### 4.2 Docker e o Firewall
> ⚠️ **Atenção**: O Docker manipula o `iptables` diretamente e ignora as regras do UFW.
> Para expor portas de contêineres apenas localmente, use `-p 127.0.0.1:8080:8080` ou utilize o utilitário `ufw-docker`.

---

## Fase 5 — Fail2ban

Criar `/etc/fail2ban/jail.local`:
```ini
[DEFAULT]
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

Iniciar e testar:
```bash
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd
```

---

## Fase 6 — Kernel Hardening (sysctl)

Arquivo `/etc/sysctl.d/99-hardening.conf`:
- Proteção contra spoofing (Reverse path filtering)
- Drop em ICMP redirects (anti MITM)
- SYN cookies contra SYN flood
- ASLR máximo (`kernel.randomize_va_space = 2`)
- Restrição de ponteiros em `/proc` e logs do kernel (`dmesg_restrict = 1`)

Aplicar:
```bash
sysctl --system
```

---

## Fase 7 — Atualizações Automáticas

```bash
apt install unattended-upgrades apt-listchanges -y
cat <<'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades --now
```

---

## 🔧 Comandos Úteis de Diagnóstico

```bash
# Serviços escutando na rede
ss -tunap

# Status e regras do firewall
ufw status numbered

# Status dos jails do fail2ban
fail2ban-client status
fail2ban-client status sshd

# Desbanir IP no fail2ban
fail2ban-client set sshd unbanip <IP>

# Testar sintaxe do sshd antes de reiniciar
sshd -t

# Logs de autenticação em tempo real
journalctl -u ssh -f
```
