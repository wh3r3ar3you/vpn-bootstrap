# Changelog

Все значимые изменения проекта будут фиксироваться в этом файле.

Формат ориентирован на Keep a Changelog, версионирование можно вести в удобном для репозитория виде.

## [Unreleased]

### Added

- интерактивный `bootstrap.sh` с вводом hostname, SSH port и публичного SSH key
- `install.sh` для one-line установки напрямую с GitHub
- безопасная настройка `authorized_keys` без перезаписи существующих ключей
- валидация SSH port и безопасное обновление `/etc/ssh/sshd_config` с проверкой через `sshd -t`
- отдельный updater `scripts/update-traffic-guard.sh`
- атомарное обновление blocklist через временный `ipset` и `ipset swap`
- защита updater от параллельных запусков через `flock` и уникальный временный `ipset`
- логирование обновления Traffic Guard в `/var/log/traffic-guard-update.log`
- `systemd service` и `systemd timer` для ежедневного обновления blocklist
- идемпотентное применение `iptables`-правил
- `README.md`, `.gitignore`, `.editorconfig`, `.gitattributes`
- GitHub Actions workflow для `bash -n` и `shellcheck`
- `LICENSE`

### Changed

- `install.sh` больше не зависит от `git`: installer проверяет базовые утилиты, ставит недостающее и скачивает архив репозитория
- `bootstrap.sh` теперь проверяет apt-пакеты и ставит только отсутствующие, включая `openssh-server` на пустых образах
