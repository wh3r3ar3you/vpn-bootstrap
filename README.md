# init-vpn-node

🚀 Первичная конфигурация для VPN-ноды на Debian/Ubuntu.

Скрипт поднимает базовую конфигурацию сервера, настраивает SSH, ставит Docker, Zsh-окружение, Speedtest CLI, firewall и отдельный механизм ежедневного обновления blocklist через `ipset` + `systemd timer`.

## ✨ Что делает проект

Проект устанавливает и настраивает:

- обновление системы и базовые пакеты для администрирования
- проверку базовых зависимостей и установку недостающих компонентов перед bootstrap
- Docker через официальный install script
- Oh My Zsh, Powerlevel10k и плагины для `root`
- Speedtest CLI
- sysctl-настройки для VPN-сценария
- интерактивную настройку hostname, SSH port и `root` SSH key
- Traffic Guard blacklist на базе `ipset` + `iptables`
- ежедневное безопасное обновление blocklist через `systemd timer`
- сохранение firewall-правил через `netfilter-persistent`

## 📋 Требования

- Debian или Ubuntu
- запуск от `root`
- рабочий исходящий доступ в интернет
- `systemd`

## 📁 Структура репозитория

- `bootstrap.sh` — основной bootstrap-скрипт
- `install.sh` — one-line installer для быстрого запуска с GitHub
- `scripts/update-traffic-guard.sh` — updater blocklist для ручного и автоматического запуска
- `systemd/traffic-guard-update.service` — `systemd service` для обновления
- `systemd/traffic-guard-update.timer` — ежедневный `systemd timer`
- `README.md` — документация проекта
- `CHANGELOG.md` — журнал изменений
- `LICENSE` — лицензия проекта
- `.gitignore` — базовая git-гигиена
- `.github/workflows/shellcheck.yml` — CI-проверка shell-скриптов

## ▶️ Как запустить

### Вариант 1: установка одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wh3r3ar3you/vpn-bootstrap/main/install.sh)
```

Что делает эта команда:

- скачивает `install.sh` из GitHub
- при необходимости ставит минимальные зависимости для запуска installer
- скачивает архив репозитория во временный каталог
- запускает `bootstrap.sh`

### Вариант 2: запуск из клонированного репозитория

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

Во время запуска скрипт спросит:

- hostname
- SSH port
- публичный SSH key для добавления в `/root/.ssh/authorized_keys`

Если SSH port оставить пустым, будет использован порт `22`.

## ⚡ Быстрый сценарий установки

Для нового сервера, можно выполнить одну команду:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wh3r3ar3you/vpn-bootstrap/main/install.sh)
```

После этого installer:

1. скачает install-скрипт
2. клонирует репозиторий `wh3r3ar3you/vpn-bootstrap`
3. запустит `bootstrap.sh`
4. попросит ввести hostname, SSH port и публичный SSH key

## 🛠 Что меняет bootstrap

`bootstrap.sh`:

- задаёт hostname и обновляет `/etc/hosts`
- пишет `/etc/sysctl.d/99-disable-ipv6.conf`
- пишет `/etc/sysctl.d/99-vpn-tuning.conf`
- выполняет `sysctl --system`
- выполняет `apt-get update` и `apt-get -y upgrade`
- проверяет apt-пакеты и устанавливает только отсутствующие через `apt-get`
- устанавливает и включает Docker
- настраивает Zsh-окружение для `root`
- устанавливает Speedtest CLI
- при необходимости ставит `openssh-server` до изменения `sshd_config`
- создаёт `/root/.ssh` и `/root/.ssh/authorized_keys` с корректными правами
- добавляет переданный публичный SSH key без затирания уже существующих ключей
- обновляет `/etc/ssh/sshd_config`, валидирует его через `sshd -t` и только потом перезапускает SSH
- устанавливает updater в `/usr/local/sbin/update-traffic-guard.sh`
- устанавливает и включает `traffic-guard-update.service` и `traffic-guard-update.timer`
- гарантирует наличие ровно одного правила `DROP` для `ipset blacklist`
- гарантирует наличие ровно одного правила блокировки `ICMP echo-request`
- сохраняет firewall-правила через `netfilter-persistent save` только после успешного применения

## ⚙️ Какие sysctl-настройки включает скрипт

Bootstrap записывает два файла:

- `/etc/sysctl.d/99-disable-ipv6.conf`
- `/etc/sysctl.d/99-vpn-tuning.conf`

После этого применяется `sysctl --system`.

### Отключение IPv6

Включаются:

- `net.ipv6.conf.all.disable_ipv6=1`
- `net.ipv6.conf.default.disable_ipv6=1`
- `net.ipv6.conf.lo.disable_ipv6=1`

Это полностью отключает IPv6 на сервере, включая loopback-интерфейс.

### Сетевой тюнинг для VPN-ноды

Включаются следующие параметры:

- `net.core.default_qdisc=fq`
- `net.ipv4.tcp_congestion_control=bbr`
- `net.ipv4.conf.all.rp_filter=0`
- `net.ipv4.conf.default.rp_filter=0`
- `net.core.rmem_max=67108864`
- `net.core.wmem_max=67108864`
- `net.core.rmem_default=262144`
- `net.core.wmem_default=262144`
- `net.core.netdev_max_backlog=250000`
- `net.core.somaxconn=4096`
- `net.ipv4.tcp_fastopen=3`
- `net.ipv4.tcp_rmem=4096 87380 67108864`
- `net.ipv4.tcp_wmem=4096 65536 67108864`
- `net.ipv4.tcp_mtu_probing=1`

Что это означает на практике:

- `fq` включается как queue discipline по умолчанию, что нужно для корректной работы BBR.
- `bbr` включается как алгоритм TCP congestion control. Это современный congestion control от Google, который обычно даёт лучшую утилизацию канала и более стабильную задержку по сравнению с классическими алгоритмами на ряде VPN-нагрузок.
- `rp_filter=0` отключает strict reverse path filtering. Это важно для серверов с нестандартной маршрутизацией, policy routing, туннелями и VPN-сценариями, где слишком жёсткая проверка обратного пути может приводить к потере пакетов.
- `rmem_max` и `wmem_max` увеличивают максимальные размеры receive/send buffer в ядре.
- `rmem_default` и `wmem_default` задают базовые значения буферов сокетов.
- `netdev_max_backlog=250000` увеличивает размер очереди входящих пакетов в ядре при высокой нагрузке.
- `somaxconn=4096` увеличивает верхнюю границу очереди ожидающих TCP-соединений.
- `tcp_fastopen=3` включает TCP Fast Open и для клиента, и для сервера.
- `tcp_rmem` и `tcp_wmem` расширяют диапазоны автонастройки TCP-буферов.
- `tcp_mtu_probing=1` включает MTU probing, что помогает переживать проблемы с path MTU и blackhole-сценарии.

Итог: после установки сервер получает более агрессивный и практичный сетевой профиль под VPN/туннельную нагрузку, а не дефолтные conservative-настройки дистрибутива.

## 🧱 Как работает daily update Traffic Guard

Updater использует безопасную атомарную схему:

1. создаёт или использует активный `ipset` `blacklist`
2. создаёт уникальный временный `ipset` вида `blacklist_new_<pid>`
3. скачивает blocklist через `curl -fsSL`
4. очищает данные от пустых строк, комментариев и дублей
5. пропускает невалидные записи
6. заполняет временный set
7. выполняет `ipset swap <temp_set> blacklist`
8. удаляет временный set

Такой подход не снимает блокировку даже на короткий момент. Если загрузка, валидация или заполнение нового set завершаются ошибкой, активный `blacklist` остаётся без изменений.

Дополнительно updater берёт lock через `flock`, поэтому параллельные запуски от `systemd timer` и вручную не конфликтуют между собой.

Логи обновления пишутся в `/var/log/traffic-guard-update.log`.

## 🔎 Как проверить timer и service

```bash
systemctl status traffic-guard-update.timer
systemctl list-timers traffic-guard-update.timer
systemctl status traffic-guard-update.service
```

## 🔁 Как обновить blocklist вручную

```bash
/usr/local/sbin/update-traffic-guard.sh
```

## ⚠️ Предупреждение

Проект меняет:

- SSH port
- firewall-правила
- sysctl-конфигурацию

Используйте bootstrap только на сервере, где у вас есть консольный или аварийный доступ на случай rollback.
