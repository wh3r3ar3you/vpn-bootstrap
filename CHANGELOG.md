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
- опциональный VPN defense profile с auto-tuned conntrack/backlog sysctl и `iptables` hashlimit rules

### Changed

- `install.sh` больше не зависит от `git`: installer проверяет базовые утилиты, ставит недостающее и скачивает архив репозитория
- `bootstrap.sh` теперь проверяет apt-пакеты и ставит только отсутствующие, включая `openssh-server` на пустых образах
- расширен Linux/VPN tuning: IPv4 forwarding, `src_valid_mark`, больший backlog/socket buffers, TCP/UDP tuning и conntrack-параметры
- SSH hardening теперь явно включает key-only root login, отключает password login и не трогает `Match`-блоки при правке `sshd_config`
- Traffic Guard применяет blocklist для `INPUT`, `FORWARD` и `OUTPUT`, а forwarded TCP получает `TCPMSS --clamp-mss-to-pmtu` в `mangle`
- добавлены container-aware firewall rules через `DOCKER-USER` для Docker VPN-сервисов
- updater blocklist использует retry/timeout для загрузок и bulk-загрузку через `ipset restore`
- `traffic-guard-update.service` ограничен capability-набором и write paths через systemd hardening
- добавлена опциональная установка XanMod LTS kernel с автоопределением `x86-64-v1/v2/v3`
- при выборе XanMod LTS bootstrap теперь отдельно спрашивает про автоматический reboot после успешной установки
