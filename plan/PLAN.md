# Plano de Correção — vps_hardening

> Criado em 2026-10-10 a partir da revisão de `hardening.sh`, `rollback.sh`, `verify.sh`, `configs/` e CI.
> Status: **implementado em 2026-10-10** (Etapas 1–8, um commit por etapa). Pendências externas na seção “Critério de pronto”.

## Ordem de execução

A ordem leva em conta as dependências entre os itens: o rollback (Etapa 3) depende de onde o alerta passa a guardar os dados (Etapa 2), e o teste E2E no CI (Etapa 6) depende do modo não interativo (Etapa 4).

| Etapa | Escopo | Itens da revisão | Severidade |
| :--- | :--- | :--- | :--- |
| 1 | Correções pontuais | #2, #3, #6, #11 | 🔴 / 🟠 |
| 2 | Refatorar o alerta SSH | #4, #5 | 🔴 / 🟠 |
| 3 | Rollback completo | #1 | 🔴 |
| 4 | Proteção contra lockout e modo não interativo | #7, + bug novo (prompt de senha com `-y`) | 🟠 |
| 5 | Alinhar o dry-run com a execução real | #8 | 🟡 |
| 6 | CI: lint, drift de `configs/`, teste E2E | #9, CI | 🟡 / ⚪ |
| 7 | Documentação | #10, aviso de firewall do provedor, SECURITY.md, CHANGELOG | 🟡 / ⚪ |
| 8 | Release, versão e checksum | `--version`, SHA256SUMS | ⚪ |

Cada etapa vira um commit próprio, para facilitar a revisão e um eventual revert.

---

## Etapa 1 — Correções pontuais

### [x] 1.1 `rollback.sh`: variável errada (#2)
- **Onde:** `rollback.sh:23-24`. O código usa `$backup_dir`, mas a variável é `$BACKUP_DIR`, e o `set -u` derruba o script.
- **Correção:** trocar por `$BACKUP_DIR`. *(A Etapa 3 reescreve esse arquivo; o fix entra antes para não ficar quebrado no meio do caminho.)*

### [x] 1.2 `LYNIS_SCORE` não definido (#3)
- **Onde:** `hardening.sh:1263` (só é definido dentro do `else` da Fase 10) e `hardening.sh:1452` (onde é lido).
- **Correção:**
  - Declarar `LYNIS_SCORE="N/A"` junto das variáveis padrão (`hardening.sh:~132`).
  - Quando a Fase 10 for pulada com `RUN_AUDIT=true`, ler o índice de `/var/log/lynis-hardening-report.txt`.
- **Teste:** rodar duas vezes com `--audit`; na segunda execução o resumo final precisa aparecer sem `unbound variable`.

### [x] 1.3 `read_input` com `eval` (#6)
- **Onde:** `hardening.sh:57`.
- **Correção:** trocar `eval "$varname=\"$value\""` por `printf -v "$varname" '%s' "$value"`.
- **Teste:** no wizard, digitar `teste"$(touch /tmp/pwned)"` como usuário. Nada pode ser executado, e a validação de username deve rejeitar a entrada.

### [x] 1.4 Fase 1 pula o `apt-get upgrade` (#11)
- **Onde:** `hardening.sh:655-679`.
- **Correção:** o `apt-get update && apt-get upgrade` passa a rodar sempre, porque ele já é idempotente. Só a instalação de `sudo`/`curl` e a configuração de timezone/NTP continuam sendo puladas quando já estão OK. Adicionar a flag `--skip-upgrade` para quem quiser evitar o upgrade.
- Documentar a nova flag no `--help` (as duas cópias, `hardening.sh:65` e `:157`) e no README.
- **Extra:** o texto de ajuda está duplicado (`hardening.sh:63-92` e `show_help`). Remover o loop inicial e mover `show_help` para antes dele, deixando uma única fonte.

---

## Etapa 2 — Refatorar o alerta SSH (#4, #5)

**Problema:** o token, o chat ID e a URL do webhook são injetados com `sed` no script `/usr/local/bin/ssh-login-alert.sh`, que tem modo `755`. Isso causa dois problemas: um `&` ou `|` na URL corrompe o valor, e o token fica legível por qualquer usuário local.

### [x] 2.1 Separar os segredos do script
- Criar `/etc/vps-hardening/alert.conf` (dono `root:root`, modo `600`) gravado com `printf '%s=%q\n'` para cada variável. Nada de `sed`.
- O script de alerta faz `source /etc/vps-hardening/alert.conf` (ou sai com `exit 0` se o arquivo não existir).
- Script de alerta: `root:root`, modo `700` (não contém mais segredos, mas não há motivo para outros usuários o executarem).
- Remover o bloco de `sed` (`hardening.sh:1357-1359`).

### [x] 2.2 Fonte única do script de alerta
- O conteúdo do heredoc (`hardening.sh:1295-1355`) passa a ser idêntico a `configs/ssh-login-alert.sh`, adaptado para ler o `alert.conf`. O check de drift da Etapa 6 garante que os dois continuem iguais.

### [x] 2.3 Escapar o JSON do webhook
- `HOST`, `USER` e `IP` entram crus no JSON. Escapar `\` e `"` antes de montar o payload, com uma função `json_escape` simples em bash.

### [x] 2.4 Idempotência da Fase 11
- **Onde:** `hardening.sh:1283-1289`. Hoje a fase faz `grep` do token dentro do script.
- **Correção:** comparar com o conteúdo de `alert.conf`, usando `grep -qxF`, que também evita interpretar o token como regex.

### [x] 2.5 Mensagem de teste
- `TEST_MSG` (`hardening.sh:1371`) é montada mas nunca usada. Remover a variável ou usá-la de fato.

**Testes:**
- Webhook `https://example.com/hook?a=1&b=2|x` → `alert.conf` guarda o valor exato.
- `stat -c '%a %U' /etc/vps-hardening/alert.conf` deve retornar `600 root`.
- Login SSH real numa VM de teste dispara o alerta. Isso também confirma que o `pam_exec` com `seteuid` roda como root e consegue ler o arquivo `600`. ✅ Validado em container Debian 12 com sshd e login real.

---

## Etapa 3 — Rollback completo (#1)

**Problema:** `tar -x` restaura os arquivos antigos, mas não remove os criados depois. O SSH continua na porta nova, os sysctl/modprobe/limits seguem ativos, o UFW continua ligado e o `ssh.socket`, desabilitado.

### [x] 3.1 Ampliar o snapshot
Adicionar ao `create_rollback_snapshot` (`hardening.sh:252-262`):
- `/etc/systemd/coredump.conf.d`
- `/etc/modules-load.d`
- `/usr/local/bin/ssh-login-alert.sh`
- `/etc/vps-hardening`

### [x] 3.2 Manifesto de arquivos criados
- Ao lado de cada `hardening_backup_<ts>.tar.gz`, gravar `hardening_backup_<ts>.created`: a lista de arquivos que o script vai criar e que **ainda não existiam** antes do hardening:
  - `/etc/ssh/sshd_config.d/00-hardening.conf`
  - `/etc/fail2ban/jail.local`
  - `/etc/sysctl.d/99-hardening.conf`
  - `/etc/modprobe.d/hardening.conf`
  - `/etc/security/limits.d/10-hardening-coredump.conf`
  - `/etc/systemd/coredump.conf.d/disable.conf`
  - `/etc/modules-load.d/bbr.conf`
  - `/usr/local/bin/ssh-login-alert.sh`
  - `/etc/vps-hardening/alert.conf`
  - `/etc/apt/apt.conf.d/20auto-upgrades`
  - os arquivos `*.bak` gerados em `/etc/ssh` e `/etc/pam.d`
- Manter essa lista numa única constante (array `HARDENING_MANAGED_FILES`) usada tanto pelo snapshot quanto pelo dry-run.

### [x] 3.3 Estado de serviços e kernel
Gravar `hardening_backup_<ts>.state` (formato `chave=valor`) com:
- `ufw_active=yes|no`
- `ssh_socket_enabled=yes|no`
- `unattended_upgrades_enabled=yes|no`
- os valores atuais de cada chave sysctl que o script altera (lidos com `sysctl -n`)

### [x] 3.4 Uma única implementação de rollback
- `rollback.sh` vira a fonte da verdade, com toda a lógica.
- `hardening.sh` instala uma cópia em `/usr/local/sbin/hardening-rollback`, no mesmo esquema do `verify-hardening` (`hardening.sh:1390-1399`), e `--rollback` faz `exec` dela.
- Fluxo do rollback:
  1. Extrair o `.tar.gz`.
  2. Remover cada arquivo listado no `.created`.
  3. Reaplicar os valores do `.state`: `sysctl -w` em cada chave; `ufw disable` se antes estava inativo; `systemctl enable --now ssh.socket` se antes estava habilitado.
  4. `sysctl --system`, depois `sshd -t`, e só então reiniciar o SSH. **Se o `sshd -t` falhar, não reiniciar** e manter a sessão atual.
  5. Reiniciar o `fail2ban`.
- Snapshots antigos (sem `.created`/`.state`) continuam funcionando no modo atual, com um aviso.
- `latest.tar.gz` passa a apontar para o snapshot **mais antigo** da execução original, não para o mais recente. Hoje, rodar o hardening duas vezes faz o `latest` apontar para um estado que já estava endurecido. Alternativa: só criar um snapshot novo quando não existir nenhum, e expor `--rollback <arquivo>` para escolher.
  - **Decisão necessária:** ver a seção “Decisões”.

**Testes (numa VM descartável):**
1. Hardening, depois rollback → `ss -tlnp` mostra o sshd na porta 22; `ufw status` mostra `inactive`; nenhum arquivo da lista existe; `sysctl net.ipv4.tcp_congestion_control` volta ao valor original.
2. Rollback rodado por `rollback.sh` direto, por `hardening.sh --rollback` e por `hardening-rollback`: os três dão o mesmo resultado.

---

## Etapa 4 — Proteção contra lockout e modo não interativo (#7)

### [x] 4.1 Bug novo: `-y` ainda pede senha
- **Onde:** `hardening.sh:732-743`. Com `-y`, o `passwd` interativo continua sendo chamado se a conta estiver sem senha, o que trava automações (cloud-init, CI).
- **Correção:** aceitar `--password-hash '<hash>'` (ou a variável `HARDENING_PASSWORD_HASH`) e aplicar com `usermod -p`. Com `-y` e sem hash, abortar antes de qualquer mudança com uma mensagem clara.
  - **Decisão necessária:** outra opção seria `--nopasswd-sudo`, que cria `/etc/sudoers.d/<user>` com `NOPASSWD`. É mais prático, mas menos seguro.

### [x] 4.2 Abrir a porta no UFW antes de reiniciar o SSH
- **Problema:** se o UFW já estiver ativo (imagens de alguns provedores), a Fase 3 move o SSH para a porta nova antes de a Fase 4 liberá-la.
- **Correção:** na Fase 3, antes do `systemctl restart` (`hardening.sh:865`), se `ufw status` estiver `active`, rodar `ufw limit "$SSH_PORT"/tcp`.

### [x] 4.3 Timer de reversão automática
- Antes de reiniciar o SSH na Fase 3, agendar com `systemd-run --unit=vps-hardening-autorevert --on-active=10min /usr/local/sbin/hardening-rollback --yes`.
- No fim do script: “Teste o login num NOVO terminal e digite `CONFIRMO` aqui (ou rode `sudo systemctl stop vps-hardening-autorevert.timer`)”. Ao confirmar, o timer é parado.
- Flag `--no-safety-timer` para desligar.
- **Decisão necessária:** comportamento padrão com `-y` (ver “Decisões”).

### [x] 4.4 Aviso sobre o firewall do provedor
- No wizard, no resumo antes da confirmação e no resumo final: “Libere a porta `$SSH_PORT/tcp` também no firewall do provedor (Hetzner Cloud Firewall, AWS Security Group, DigitalOcean Cloud Firewall, etc.)”.

**Testes:**
- `-y` sem hash → aborta antes do snapshot, sem nenhuma mudança no sistema.
- `-y --password-hash` → termina sem nenhum prompt.
- Com o UFW ativo liberando só a 22 → depois do hardening, a sessão nova na porta nova conecta.
- Sem confirmar, o sistema reverte em 10 minutos e o SSH volta para a porta 22.

---

## Etapa 5 — Alinhar o dry-run (#8)

### [x] 5.1 Corrigir os textos
- **Onde:** `hardening.sh:483-636`. Bater cada linha com a execução real:
  - Fail2ban: é `/etc/fail2ban/jail.local`, não `jail.d/00-ssh-hardening.local`, com `maxretry 3`, `findtime 300` e `bantime 7200` no jail sshd, mais o incremento progressivo.
  - A Fase 5 também instala o `tmux`. Ou o dry-run passa a mencionar isso, ou (melhor) o `tmux` sai da fase, porque não tem relação com o fail2ban.
  - O SSH também grava `KbdInteractiveAuthentication no`, `LoginGraceTime 20`, `ClientAliveInterval 300` e `ClientAliveCountMax 2`.
  - Coredump: o arquivo real é `/etc/systemd/coredump.conf.d/disable.conf`, não `/etc/systemd/coredump.conf`.

### [x] 5.2 Mesma numeração de fases
- 1 Base · 2 Usuário · 3 SSH · 4 UFW · 5 Fail2ban · 6 sysctl · 7 Unattended · 8 `/dev/shm` + coredump · 9 modprobe · 10 auditd/Lynis · 11 Alertas.
- Hoje o dry-run usa 8 = shm, 9 = coredump, 10 = modprobe e tem duas Fases 11.

### [x] 5.3 Mostrar o snapshot e o timer
- O dry-run deve listar os itens novos das Etapas 3 e 4: o snapshot, o manifesto e o timer de reversão.

**Teste:** comparar, lado a lado, a saída do `--dry-run` com a de uma execução real na VM.

---

## Etapa 6 — CI e drift de `configs/` (#9)

### [x] 6.1 Lint completo
- **Onde:** `.github/workflows/ci.yml`. Incluir `verify.sh` no `bash -n` e no `shellcheck`.
- Rever as exclusões globais `-e SC2086 -e SC2034`: trocar por `# shellcheck disable=` pontuais onde forem realmente necessárias.

### [x] 6.2 Check de drift
- **Decisão adotada:** `configs/` continua como *template de referência* para quem aplica manualmente. O `hardening.sh` mantém os heredocs, porque precisa funcionar via `curl | bash` sem baixar arquivos no meio da execução.
- Criar `tests/check-config-drift.sh`: extrai cada heredoc do `hardening.sh`, normaliza a porta/usuário (`52211`/`operator` ↔ `$SSH_PORT`/`$NOVO_USUARIO`) e faz `diff` com o arquivo correspondente em `configs/`. Falha no CI se houver diferença.

### [x] 6.3 Teste E2E num runner real
- Novo job em `ubuntu-22.04` e `ubuntu-24.04` (VMs efêmeras do GitHub, com root e systemd):
  1. `sudo ./hardening.sh -y --password-hash ... --no-safety-timer -u ciuser -k "<chave gerada no job>" -p 52211`
  2. `sudo ./verify.sh --port 52211 --user ciuser`, que tem que sair com 0 falhas. Conferir que o `verify.sh` retorna exit code ≠ 0 quando há falhas; se não retornar, corrigir.
  3. `ssh -i <chave> -p 52211 ciuser@127.0.0.1 true`
  4. `sudo ./rollback.sh --yes`, depois validar que o SSH volta para a 22 e que os arquivos do manifesto sumiram.
  5. Rodar o hardening duas vezes seguidas para validar a idempotência e o caso do `LYNIS_SCORE`.
- A matriz de dry-run em containers continua cobrindo Debian 11/12.
- ✅ O job E2E passou no GitHub (PR #1) em ubuntu-22.04 e ubuntu-24.04.

---

## Etapa 7 — Documentação (#10)

- [x] **7.1** Traduzir para inglês as seções do README que ficaram em português: “Configuração de Notificações via Telegram” e “Usabilidade e Flexibilidade Operacional”, incluindo dry-run e rollback.
- [x] **7.2** Documentar as flags novas: `--skip-upgrade`, `--password-hash`, `--no-safety-timer` e `--version`.
- [x] **7.3** Atualizar a seção de rollback para refletir o comportamento novo (remoção de arquivos e restauração de estado).
- [x] **7.4** Adicionar o aviso de firewall do provedor às “Golden Rules”.
- [x] **7.5** Atualizar o “Repository Layout” com `plan/`, `tests/`, `SECURITY.md` e `CHANGELOG.md`.
- [x] **7.6** Criar `SECURITY.md`: como reportar vulnerabilidades e o escopo do projeto.
- [x] **7.7** Revisar o `GUIDE.md` para os mesmos pontos.

---

## Etapa 8 — Release e integridade

- [x] **8.1** Adicionar `VERSION="x.y.z"` no topo do `hardening.sh` e do `verify.sh`, mais a flag `--version`. Mostrar a versão no cabeçalho do wizard e no resumo.
- [x] **8.2** Criar `CHANGELOG.md` (formato Keep a Changelog), começando pela versão que fecha este plano.
- [x] **8.3** Workflow de release: em cada tag `v*`, gerar `SHA256SUMS` dos scripts e anexar ao GitHub Release.
- [x] **8.4** `quick-install.sh` e o README passam a apontar para uma **tag** (`/v1.0.0/`) em vez de `main`, e o `quick-install.sh` valida os arquivos com `sha256sum -c` antes de executar.

---

## Decisões tomadas

1. **Etapa 3, snapshot:** criado só na primeira execução; `latest.tar.gz` sempre aponta para o estado original e execuções seguintes o mantêm.
2. **Etapa 4.1, senha no modo `-y`:** `--password-hash` (hash crypt, ex.: `openssl passwd -6`). Sem ele, com `-y` ou sem terminal, a execução aborta antes de qualquer mudança.
3. **Etapa 4.3, timer de reversão:** ligado por padrão no modo interativo, desligado com `-y`; `--safety-timer` / `--no-safety-timer` sobrescrevem.

## Critério de pronto

- [x] Todos os itens marcados.
- [x] CI verde: lint, drift, matriz de dry-run (Ubuntu 20.04/22.04/24.04, Debian 12/13) e E2E em 22.04/24.04. *(PR #1)*
- [ ] Teste manual numa VPS real (Debian 12 e Ubuntu 24.04): hardening → login na porta nova → rollback → login na porta 22. *(validado localmente em containers systemd; sysctl, `/dev/shm` e auditd não puderam ser exercitados em container)*
- [x] Criar e publicar a tag `v1.0.0` depois do merge na `main`. *(release publicada; seguida da `v1.0.1` com as correções da Fase T5 do TEST-PLAN)*
