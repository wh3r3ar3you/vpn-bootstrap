# Changelog

Все значимые изменения проекта будут фиксироваться в этом файле.

Формат ориентирован на Keep a Changelog, версионирование можно вести в удобном для репозитория виде.

## [Unreleased]

### Added

- интерактивный `bootstrap.sh` с вводом hostname, SSH port и публичного SSH key
- безопасная настройка `authorized_keys` без перезаписи существующих ключей
- валидация SSH port и безопасное обновление `/etc/ssh/sshd_config` с проверкой через `sshd -t`
- отдельный updater `scripts/update-traffic-guard.sh`
- атомарное обновление blocklist через временный `ipset` и `ipset swap`
- логирование обновления Traffic Guard в `/var/log/traffic-guard-update.log`
- `systemd service` и `systemd timer` для ежедневного обновления blocklist
- идемпотентное применение `iptables`-правил
- `README.md`, `.gitignore`, `.editorconfig`, `.gitattributes`
- GitHub Actions workflow для `bash -n` и `shellcheck`
- `LICENSE`
