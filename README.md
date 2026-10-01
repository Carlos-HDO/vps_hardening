# VPS Hardening Automation (`vps_hardening`)

Automação completa e modular de **Hardening para Servidores VPS** recém-criados executando **Ubuntu (20.04/22.04/24.04 LTS)** e **Debian (11/12+)**.

Aplica as melhores práticas de segurança da indústria para transformar uma VPS padrão exposta à internet em uma máquina fortificada contra bots, ataques de força bruta, spoofing de IP e explorações de memória.

---

## ⚡ Funcionalidades (As 7 Fases de Segurança)

- **Fase 1 — Atualização e Sincronização**: Atualização não-interativa do sistema (`apt-get upgrade`), fuso horário definido e sincronização ativa de horário com NTP.
- **Fase 2 — Gestão Segura de Contas**: Criação de usuário administrativo no grupo `sudo`, neutralização de contas padrões vulneráveis de provedores cloud (`ubuntu`, `debian`, `admin`) e desativação de chaves não autorizadas.
- **Fase 3 — SSH Hardening & Socket Activation**: Desativação total de login por senha (`PasswordAuthentication no`) e login direto como root (`PermitRootLogin no`), migração para porta alta customizada, resolução do *systemd socket activation* do Ubuntu 22.10/24.04 e testes de sintaxe antes de reiniciar.
- **Fase 4 — Firewall Restritivo (UFW)**: Política `deny incoming`, liberação da porta SSH personalizada com rate-limit nativo (`ufw limit`) e cobertura para IPv6.
- **Fase 5 — Proteção contra Brute Force (Fail2ban)**: Criação de `/etc/fail2ban/jail.local` com incrementos progressivos de ban, sub-redes Docker e RFC1918 ignoradas e monitoramento do SSH.
- **Fase 6 — Kernel Hardening (sysctl)**: Bloqueio de pacotes com Source Routing, ignorar ICMP redirects (anti-MITM), proteção contra SYN Flood (`syncookies`), ASLR máximo (`randomize_va_space = 2`), restrição de ponteiros em `/proc` e `dmesg_restrict`.
- **Fase 7 — Atualizações Automáticas de Segurança**: Configuração ativa do `unattended-upgrades` para correções contínuas de vulnerabilidades críticas do SO.

---

## ⚠️ Regras de Ouro (Antes de Começar)

> [!CAUTION]
> 1. **Nunca feche a sessão SSH atual** durante a execução do hardening! Se algo falhar, você precisará da sessão aberta para diagnosticar.
> 2. **Sempre teste a nova conexão em um NOVO terminal** com a chave SSH e o novo usuário antes de encerrar a sessão root.
> 3. Crie um **snapshot** da VPS no painel do seu provedor (Contabo, Hetzner, DigitalOcean, etc.) antes de iniciar.

---

## 🚀 Como Executar

### 1. Via Git Clone (Recomendado)

Clone o repositório na VPS e execute o script:

```bash
git clone https://github.com/carlos-hdo/vps_hardening.git
cd vps_hardening
chmod +x hardening.sh
sudo ./hardening.sh
```

### 2. One-Liner com Argumentos Diretos

Você pode passar o usuário, a chave pública e a porta SSH desejada:

```bash
sudo ./hardening.sh operador "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... vps-acesso" 52211
```

Ou com flags nomeadas:

```bash
sudo ./hardening.sh -u operador -k "ssh-ed25519 AAAAC3..." -p 52211 -y
```

### 3. Via Pipe Direto (Curl / Web Bootstrap)

Se preferir executar diretamente via one-liner remoto:

```bash
# Modo Interativo (o script detecta /dev/tty e solicita os dados com segurança)
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash

# Ou passando os parâmetros diretamente:
curl -fsSL https://raw.githubusercontent.com/carlos-hdo/vps_hardening/main/hardening.sh | sudo bash -s -- operador "ssh-ed25519 AAAAC3..." 52211
```

---

## 🛠️ Opções de Linha de Comando

| Flag | Argumento | Padrão | Descrição |
| :--- | :--- | :--- | :--- |
| `-u`, `--user` | `<nome>` | `operador` | Nome do novo usuário administrativo |
| `-k`, `--key` | `"<chave>"` | *(obrigatório)* | Chave pública SSH autorizada (ed25519 / rsa / ecdsa) |
| `-p`, `--port` | `<número>` | `52211` | Nova porta SSH (faixa 1024 a 65535) |
| `-t`, `--timezone` | `<região>` | `America/Sao_Paulo` | Fuso horário do sistema |
| `-y`, `--yes` | Nenhum | `false` | Pula a tela de confirmação inicial |
| `-h`, `--help` | Nenhum | — | Exibe mensagem de ajuda e opções |

---

## 🧪 Verificação Pós-Instalação

Após a execução, realize os testes em um **terminal separado**:

```bash
# 1. Testar acesso com a nova chave e porta
ssh -p 52211 operador@IP_DA_VPS

# 2. Confirmar privilégio sudo
sudo whoami
# Resposta esperada: root

# 3. Travar a senha do root (somente após validar passos 1 e 2)
sudo passwd -l root
```

### Comandos de Diagnóstico Úteis:

```bash
# Verificar portas em escuta (deve mostrar a porta customizada, não mais a 22)
ss -tunap | grep sshd

# Status do firewall
sudo ufw status numbered

# Status do fail2ban
sudo fail2ban-client status sshd

# Desbanir seu próprio IP caso erre chaves consecutivas
sudo fail2ban-client set sshd unbanip SEU_IP
```

---

## 📁 Estrutura do Projeto

```
vps_hardening/
├── hardening.sh           # Script principal de automação e hardening
├── quick-install.sh       # Script de bootstrap para one-liner e execuções remotas
├── GUIDE.md               # Guia detalhado de referência técnica (Fases 1 a 7)
├── README.md              # Documentação e instruções de uso
├── LICENSE                # Licença MIT
└── configs/
    ├── 00-hardening.conf  # Template de configuração OpenSSH
    ├── jail.local         # Template de configuração Fail2ban
    └── 99-hardening.conf  # Template de parâmetros de segurança sysctl
```

---

## 📄 Licença

Distribuído sob a licença [MIT](LICENSE).
