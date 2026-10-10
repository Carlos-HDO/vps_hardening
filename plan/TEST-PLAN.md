# Plano de Testes — vps_hardening v1.0.0

> Criado em 2026-10-10, após a release `v1.0.0`.
> Versão alvo: **v1.0.1** (inclui as correções da Fase T5). Status: **pendente**. Marque cada caso com `[x]` e anote data, provedor e imagem usados.

## O que já está coberto

| Cobertura | Onde |
| :--- | :--- |
| Lint (ShellCheck 0.9–0.11), sintaxe, drift `configs/` ↔ heredocs | CI (`lint`) |
| Dry-run em Ubuntu 20.04/22.04/24.04 e Debian 12/13 | CI (`dry-run-matrix`) |
| Hardening → `verify.sh` sem falhas → login + sudo na porta nova → 2ª execução idempotente → rollback | CI (`e2e`, VMs ubuntu-22.04/24.04) |
| Mesmo ciclo + `ssh.socket` (Ubuntu 24.04), `-y` sem hash, UFW já ativo, timer sem confirmação, `CONFIRM` | Containers systemd locais (Debian 12, Ubuntu 24.04) |
| Alerta PAM com login SSH real, URL com `&`/`|`, permissões `600`/`700` | Container Debian 12 |
| `quick-install.sh`: checksum válido, adulterado e ausente; downloads públicos da release | Local + URLs da tag `v1.0.0` |

## O que ainda não foi testado

- Uma **VPS real**, com rede pública, imagem de provedor e console de resgate.
- **Reboot**: persistência após o hardening e após o rollback.
- **Debian 12/13** fora de container (sysctl, `/dev/shm`, auditd).
- **Container VPS** (LXC/OpenVZ), **ARM64** e imagens mínimas.
- **Alertas reais** (Telegram, Discord e webhook genérico).
- **Upgrade** de uma instalação anterior à v1.0.0.

## Pré-requisitos para todas as fases

- VPS descartável, com **snapshot do provedor** criado antes de cada caso.
- Acesso ao **console web/VNC** do provedor testado *antes* de começar (é a saída se tudo falhar).
- Chave de teste: `ssh-keygen -t ed25519 -f ~/.ssh/vpsh_test`.
- Hash de senha: `openssl passwd -6`.
- Registrar a saída: `sudo ./hardening.sh ... 2>&1 | tee hardening-$(date +%F).log`.

---

## Fase T1 — Smoke test em VPS real (prioridade alta)

**Objetivo:** primeira execução real nas duas distros principais, pelo caminho que o usuário final usa.

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T1.1 | Ubuntu 24.04, wizard interativo | `curl -fsSL .../v1.0.1/quick-install.sh \| sudo bash` e responder o wizard | Checksums verificados, 11 fases OK, `verify-hardening` sem FAIL, timer armado |
| [ ] T1.2 | Confirmar o timer | Testar `ssh -i ~/.ssh/vpsh_test -p 52211 operator@IP` em outro terminal e digitar `CONFIRM` | `systemctl list-timers` sem `vps-hardening-autorevert` |
| [ ] T1.3 | Debian 12, flags + `-y` | `sudo ./hardening.sh -u operator -k gh:<user> --password-hash '<hash>' -a 80,443 -y` | Sem prompts; `sudo whoami` funciona com a senha do hash |
| [ ] T1.4 | Debian 13 | Mesmo que T1.3 | Igual a T1.3 (é a primeira execução real no Debian 13) |
| [ ] T1.5 | Sysctl aplicado | `sysctl net.ipv4.conf.all.rp_filter kernel.kptr_restrict net.ipv4.tcp_congestion_control` | `1`, `2`, `bbr` |
| [ ] T1.6 | Varredura externa | Da máquina local: `nmap -Pn -p 22,52211,80,443 IP` | Só `52211`, `80` e `443` abertas; `22` fechada ou filtrada |

## Fase T2 — Reboot e persistência (prioridade alta)

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T2.1 | Reboot após o hardening | `sudo reboot` e reconectar na porta nova | SSH na porta nova; `ufw`, `fail2ban` e `auditd` ativos; `bbr` carregado; `/dev/shm` com `noexec`; `ulimit -c` = 0 |
| [ ] T2.2 | `verify-hardening` após o reboot | `sudo verify-hardening` | Mesmo resultado de antes do reboot |
| [ ] T2.3 | Reboot após o rollback | `sudo hardening-rollback`, depois `sudo reboot` | Volta na porta original; sem `99-hardening.conf`; `/dev/shm` com as opções originais; serviços que não existiam antes ficam desabilitados |
| [ ] T2.4 | Ubuntu 24.04: socket activation após rollback + reboot | `systemctl is-enabled ssh.socket ssh.service` | Mesmo estado registrado no `.state` (`enabled`/`disabled`) |

## Fase T3 — Rollback real (prioridade alta)

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T3.1 | Valores de sysctl restaurados | Antes: `sysctl -a > before.txt`. Hardening, rollback, depois `sysctl -a > after.txt` | `diff` sem diferenças nas chaves de `HARDENING_SYSCTL_KEYS` (o container não permitiu testar isso) |
| [ ] T3.2 | Usuário padrão do provedor | Numa imagem com usuário `ubuntu`/`debian`/`admin` e chave do provedor: hardening, depois rollback | Shell, status de senha e `authorized_keys` originais de volta; login como esse usuário funciona |
| [ ] T3.3 | UFW já ativo antes | Ativar o UFW com regras próprias, rodar hardening e depois rollback | `ufw status numbered` igual ao original |
| [ ] T3.4 | Rollback de arquivo específico | `sudo hardening-rollback --yes /var/backups/vps_hardening/hardening_backup_<ts>.tar.gz` | Mesmo resultado do rollback padrão |

## Fase T4 — Cenários de lockout (prioridade alta)

Rodar **sempre com snapshot e console do provedor à mão**.

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T4.1 | Chave errada | Hardening com uma chave cuja privada você não tem; não confirmar | Em ~10 min o servidor volta à porta original e o login antigo funciona |
| [ ] T4.2 | Firewall do provedor bloqueando a porta nova | Não liberar `52211` no firewall do provedor | Login falha, o timer reverte e o aviso de firewall do provedor apareceu antes |
| [ ] T4.3 | Sessão cai no meio da execução | Fechar o terminal logo após a Fase 3 | O timer de 60 min reverte. **Verificar** se a execução continua ou morre com a sessão (recomendar `tmux` no README, se morrer) |
| [ ] T4.4 | Confirmação tardia | Não digitar nada; depois rodar `sudo systemctl stop vps-hardening-autorevert.timer` | Hardening mantido |

## Fase T5 — Re-execução com parâmetros diferentes (prioridade média)

Pela leitura do código, há **comportamentos a confirmar**:

| # | Caso | Passos | Resultado esperado / a investigar |
| :--- | :--- | :--- | :--- |
| [ ] T5.1 | Trocar a porta | Rodar de novo com `-p 52222` | sshd e fail2ban passam para `52222`; a regra UFW `SSH Hardened Port` de `52211` (v4 e v6) é removida. ✅ Bug confirmado e corrigido na v1.0.1, coberto no E2E; falta validar na VPS |
| [ ] T5.2 | Trocar o usuário | Rodar de novo com `-u outro` | `AllowUsers outro <admin anterior>`, com aviso no resumo; os dois logam. ✅ Bug confirmado e corrigido, coberto no E2E; falta validar na VPS |
| [ ] T5.3 | Adicionar portas | Rodar de novo com `-a 8080` | `8080` aberta, as demais mantidas |
| [ ] T5.4 | Rollback após T5.1/T5.2 | `sudo hardening-rollback` | Volta ao estado **anterior à primeira execução** (snapshot original) |

## Fase T6 — Alertas SSH (prioridade média)

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T6.1 | Telegram | `--tg-token/--tg-chat` reais e um login SSH | Mensagem de ativação e alerta por login |
| [ ] T6.2 | Discord | `-w https://discord.com/api/webhooks/...` | Embed recebido |
| [ ] T6.3 | Webhook genérico com query string | `-w "https://webhook.site/<id>?a=1&b=2"` | JSON válido com a URL intacta |
| [ ] T6.4 | Sem rede de saída | Bloquear o tráfego de saída (`ufw deny out 443`) e fazer login | Login **não** atrasa nem falha |
| [ ] T6.5 | Credenciais protegidas | `sudo -u nobody cat /etc/vps-hardening/alert.conf` | Permissão negada |

## Fase T7 — Upgrade de instalações antigas (prioridade média)

| # | Caso | Passos | Resultado esperado |
| :--- | :--- | :--- | :--- |
| [ ] T7.1 | Instalação pré-1.0 com alertas | Hardening com o commit `29161c3` + Telegram; depois `verify-hardening` da v1.0.0 | FAIL "secrets embedded in /usr/local/bin/ssh-login-alert.sh" |
| [ ] T7.2 | Migração | Rodar o `hardening.sh` v1.0.0 com os mesmos parâmetros | Segredos movidos para o `alert.conf`; script sem token; `verify-hardening` sem FAIL |
| [ ] T7.3 | Snapshot legado | `sudo hardening-rollback` sobre um snapshot pré-1.0 | Aviso de snapshot legado; só os arquivos restaurados; nenhum erro |

## Fase T8 — Ambientes e distros adicionais (prioridade baixa)

| # | Caso | Resultado esperado |
| :--- | :--- | :--- |
| [ ] T8.1 | Container VPS (LXC/OpenVZ, ex.: Contabo VPS antigo) | Perfil sysctl de container; nenhuma falha por sysctl somente leitura |
| [ ] T8.2 | ARM64 (Hetzner CAX, Oracle Ampere) | Igual a T1 |
| [ ] T8.3 | Imagem mínima sem `sudo`/`curl` | A Fase 1 instala tudo. ⚠️ Usar `-k` com a chave em texto: `gh:usuario` precisa de `curl` *antes* da Fase 1 |
| [ ] T8.4 | Ubuntu 22.04 real | Igual a T1 |
| [ ] T8.5 | Ubuntu 20.04 | **Decidir** se continua suportado (suporte padrão encerrado, só ESM) |

## Fase T9 — Avaliação de segurança (prioridade baixa)

| # | Caso | Resultado esperado |
| :--- | :--- | :--- |
| [ ] T9.1 | Lynis antes × depois (`--audit`) | Hardening Index maior; registrar os dois valores |
| [ ] T9.2 | `ssh-audit IP -p 52211` | Registrar algoritmos fracos ainda aceitos (candidato a melhoria: `KexAlgorithms`/`Ciphers`/`MACs`) |
| [ ] T9.3 | Permissões | `/var/backups/vps_hardening` `700`; arquivos `600`; `alert.conf` `600` |
| [ ] T9.4 | Força bruta | `hydra` ou logins inválidos repetidos a partir de outro IP | Ban do fail2ban após 3 tentativas, com tempo crescente |

---

## Automatizar depois

- **Reboot e Debian no CI:** os runners do GitHub são só Ubuntu e não reiniciam no meio do job. Uma opção é usar VMs LXD/QEMU dentro do runner (`lxc launch images:debian/12 --vm`) para cobrir T2 e Debian 12/13 de verdade.
- **Execução agendada** (ex.: semanal) do job E2E, para detectar mudanças de pacotes nas imagens (como aconteceu com o Debian 11).
- ~~**T5.1/T5.2:** corrigir e adicionar o caso ao E2E~~ — feito (re-execução com nova porta e novo usuário no job `e2e`).

## Registro de execuções

| Data | Caso(s) | Provedor / imagem | Resultado | Observações |
| :--- | :--- | :--- | :--- | :--- |
| | | | | |
