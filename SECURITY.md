# Security Policy

## Supported Versions

Only the latest release (and the `main` branch) receives security fixes.

## Reporting a Vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub's [private vulnerability reporting](https://github.com/carlos-hdo/vps_hardening/security/advisories/new) ("Report a vulnerability" in the repository's **Security** tab). Include:

- affected script and version (`hardening.sh --version`) or commit;
- distribution and version where it was reproduced (e.g. Ubuntu 24.04, Debian 12);
- steps to reproduce and the impact (privilege escalation, credential exposure, lockout, …).

You should receive an acknowledgement within 7 days. Fixes are released as a new tagged version, and the advisory is published once users have had time to update.

## Scope

In scope:

- `hardening.sh`, `verify.sh`, `rollback.sh`, `quick-install.sh` and the files in `configs/`;
- files these scripts install on the server (`/usr/local/bin/ssh-login-alert.sh`, `/etc/vps-hardening/alert.conf`, snapshots in `/var/backups/vps_hardening/`).

Out of scope:

- vulnerabilities in third-party packages the scripts install (OpenSSH, UFW, Fail2ban, auditd, Lynis…) — report those upstream;
- settings deliberately changed by the operator after the hardening run.
