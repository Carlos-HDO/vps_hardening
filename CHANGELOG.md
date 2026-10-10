# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-10

First versioned release. Fixes and improvements from the review in `plan/PLAN.md`.

### Added
- Full rollback: first-run snapshot with `.created` manifest and `.state` file; `rollback.sh` (installed as `hardening-rollback`) restores files, deletes created ones and restores UFW, services, sysctl, `/dev/shm` and default cloud accounts.
- Auto-revert safety timer (`vps-hardening-autorevert`), cancelled by typing `CONFIRM`; `--safety-timer` / `--no-safety-timer`.
- `--password-hash` for non-interactive runs; `-y` without it aborts before any change when the admin account has no password.
- `--skip-upgrade`, `--version` (all scripts), `HARDENING_*` environment variables documented.
- CI: ShellCheck without global exclusions, `tests/check-config-drift.sh`, end-to-end job on Ubuntu 22.04/24.04 runners.
- Release workflow publishing `SHA256SUMS`; `quick-install.sh` installs a tagged release and verifies checksums.
- `SECURITY.md`.

### Changed
- SSH alert credentials moved to `/etc/vps-hardening/alert.conf` (root, `600`); the dispatcher no longer contains secrets and JSON-escapes payload fields.
- Snapshot archives are root-only (they contain SSH host private keys).
- Phase 1 always refreshes package lists and upgrades packages; `tmux` moved from Phase 5 to the Phase 1 baseline tools.
- If UFW is already active, the new SSH port is opened before sshd is restarted.
- Dry-run output matches the real run (phase numbering, files and values).
- Remote helper downloads are pinned to the release tag instead of `main`.
- README fully in English; GUIDE.md updated.

### Fixed
- `rollback.sh` crashed on its fallback path (`$backup_dir` typo).
- Re-running with `--audit` crashed on an unbound `LYNIS_SCORE`.
- Wizard input was passed through `eval` (command injection).
- Webhook URLs containing `&` or `|` were corrupted when installed.
- `sshd -t` failed on Ubuntu 24.04 before `ssh.service` had been socket-activated (missing `/run/sshd`).
- Unknown command-line flags exited with status 0.

[1.0.0]: https://github.com/carlos-hdo/vps_hardening/releases/tag/v1.0.0
