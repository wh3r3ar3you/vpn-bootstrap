# vpn-bootstrap

🚀 Первичная конфигурация для VPN-ноды на Debian/Ubuntu.

## О проекте

`vpn-bootstrap` — практичный opinionated bootstrap для выделенных VPN-нод. Он готовит чистый Debian/Ubuntu к высокой сетевой нагрузке, настраивает ядро и NIC, SSH, Docker, firewall и ежедневное атомарное обновление Traffic Guard blocklist.

Профиль рассчитан прежде всего на VPS с `virtio` и небольшим числом аппаратных очередей: входящий поток распределяется по CPU, очереди TCP и `fq` увеличиваются, а проблемный GRO по умолчанию отключается. Все изменения переживают перезагрузку.

## ✨ Что делает проект

Проект устанавливает и настраивает:

- обновление системы и базовые пакеты для администрирования
- проверку базовых зависимостей и установку недостающих компонентов перед bootstrap
- Docker через официальный install script
- опционально XanMod LTS kernel через официальный APT repository
- Oh My Zsh, Powerlevel10k и плагины для `root`
- Speedtest CLI
- sysctl-настройки для VPN-сценария
- постоянный NIC tuning с RPS/RFS, увеличенным `fq`, отключением GRO и `irqbalance`
- опциональный VPN defense profile с auto-tuned conntrack/backlog и `iptables` rate limits
- интерактивную настройку hostname, SSH port и `root` SSH key
- Traffic Guard blacklist на базе `ipset` + `iptables`
- ежедневное безопасное обновление blocklist через `systemd timer`
- сохранение firewall/ipset-состояния через `netfilter-persistent`, если доступно

## 📋 Требования

- Debian или Ubuntu
- запуск от `root`
- рабочий исходящий доступ в интернет
- `systemd`

## 📁 Структура репозитория

- `bootstrap.sh` — основной bootstrap-скрипт
- `install.sh` — one-line installer для быстрого запуска с GitHub
- `scripts/apply-vpn-network-tuning.sh` — применение NIC, RPS/RFS и `fq` tuning
- `scripts/update-traffic-guard.sh` — updater blocklist для ручного и автоматического запуска
- `systemd/vpn-node-network-tuning.service` — восстановление сетевых настроек после reboot
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
apt update && apt install curl -y && bash <(curl -fsSL https://raw.githubusercontent.com/wh3r3ar3you/vpn-bootstrap/main/install.sh)
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
- устанавливать ли VPN defense profile
- устанавливать ли XanMod LTS kernel
- если XanMod выбран, делать ли автоматический reboot после успешного bootstrap

Если SSH port оставить пустым, будет использован порт `22`.

## 🛠 Что меняет bootstrap

`bootstrap.sh`:

- задаёт hostname и обновляет `/etc/hosts`
- пишет `/etc/sysctl.d/99-disable-ipv6.conf`
- пишет `/etc/sysctl.d/99-vpn-tuning.conf`
- применяет sysctl через `sysctl -e -p`, чтобы неизвестные ключи старого ядра не ломали bootstrap
- выполняет `apt-get update` и `apt-get -y upgrade`
- проверяет apt-пакеты и устанавливает только отсутствующие через `apt-get`
- всегда ставит `ethtool` и `irqbalance`, включает распределение аппаратных IRQ
- определяет основной внешний интерфейс и ставит `/usr/local/sbin/apply-vpn-network-tuning.sh` + `vpn-node-network-tuning.service`
- включает RPS/RFS по всем CPU, увеличивает `fq` и отключает GRO; на multi-queue NIC сохраняет корневой `mq` и меняет только дочерние очереди
- опционально пишет `/etc/sysctl.d/99-vpn-defense.conf` и `/etc/modprobe.d/vpn-defense-conntrack.conf`
- опционально добавляет официальный XanMod APT repo и ставит `linux-xanmod-lts-x64v1/v2/v3` по уровню CPU
- если XanMod выбран и пользователь подтвердил auto reboot, перезагружает сервер после успешного завершения
- устанавливает и включает Docker
- настраивает Zsh-окружение для `root`
- устанавливает Speedtest CLI
- при необходимости ставит `openssh-server` до изменения `sshd_config`
- создаёт `/root/.ssh` и `/root/.ssh/authorized_keys` с корректными правами
- добавляет переданный публичный SSH key без затирания уже существующих ключей
- обновляет `/etc/ssh/sshd_config`, включает key-only root login, отключает password login, увеличивает pre-auth очередь до `MaxStartups 100:30:200`, валидирует конфиг через `sshd -t` и только потом перезапускает SSH
- устанавливает updater в `/usr/local/sbin/update-traffic-guard.sh`
- устанавливает и включает `traffic-guard-update.service` и `traffic-guard-update.timer`
- гарантирует наличие правил `DROP`/`REJECT` для `ipset blacklist` во входящем, исходящем и forwarded-трафике
- добавляет те же blocklist-ограничения в `DOCKER-USER`, если цепочка создана Docker
- добавляет `TCPMSS --clamp-mss-to-pmtu` в `mangle/FORWARD` для туннельного TCP-трафика
- если выбран VPN defense profile, добавляет comment-based `iptables` rules для SYN hashlimit, UDP amplification filter и ICMP echo-request rate limit
- гарантирует наличие ровно одного правила блокировки `ICMP echo-request`
- сохраняет firewall-правила через `netfilter-persistent save` только после успешного применения

## ⚙️ Какие sysctl-настройки включает скрипт

Bootstrap записывает два файла:

- `/etc/sysctl.d/99-disable-ipv6.conf`
- `/etc/sysctl.d/99-vpn-tuning.conf`

После этого каждый файл применяется через `sysctl -e -p`.

### Отключение IPv6

Включаются:

- `net.ipv6.conf.all.disable_ipv6=1`
- `net.ipv6.conf.default.disable_ipv6=1`

Это отключает IPv6 для обычных интерфейсов, но не трогает loopback.

### Сетевой тюнинг для VPN-ноды

Включаются следующие параметры:

- `net.core.default_qdisc=fq`
- `net.ipv4.tcp_congestion_control=bbr`
- `net.ipv4.ip_forward=1`
- `net.ipv4.conf.all.forwarding=1`
- `net.ipv4.conf.default.forwarding=1`
- `net.ipv4.conf.all.rp_filter=0`
- `net.ipv4.conf.default.rp_filter=0`
- `net.ipv4.conf.all.src_valid_mark=1`
- `net.ipv4.conf.default.src_valid_mark=1`
- `net.core.rmem_max=67108864`
- `net.core.wmem_max=67108864`
- `net.core.rmem_default=262144`
- `net.core.wmem_default=262144`
- `net.core.optmem_max=4194304`
- `net.core.netdev_max_backlog=250000`
- `net.core.netdev_budget=600`
- `net.core.netdev_budget_usecs=4000`
- `net.core.somaxconn=32768`
- `net.core.rps_sock_flow_entries=32768`
- `net.ipv4.tcp_fastopen=3`
- `net.ipv4.tcp_rmem=4096 87380 67108864`
- `net.ipv4.tcp_wmem=4096 65536 67108864`
- `net.ipv4.tcp_mtu_probing=1`
- `net.ipv4.tcp_slow_start_after_idle=0`
- `net.ipv4.tcp_notsent_lowat=16384`
- `net.ipv4.tcp_tw_reuse=1`
- `net.ipv4.tcp_max_orphans=262144`
- `net.ipv4.tcp_fin_timeout=30`
- `net.ipv4.tcp_keepalive_time=600`
- `net.ipv4.tcp_keepalive_intvl=30`
- `net.ipv4.tcp_keepalive_probes=5`
- `net.ipv4.udp_rmem_min=8192`
- `net.ipv4.udp_wmem_min=8192`
- `net.ipv4.ip_local_port_range=1024 65535`
- `net.ipv4.tcp_max_syn_backlog=32768`
- `net.netfilter.nf_conntrack_max=1048576`
- `net.netfilter.nf_conntrack_tcp_timeout_established=7440`
- `net.netfilter.nf_conntrack_udp_timeout=60`
- `net.netfilter.nf_conntrack_udp_timeout_stream=180`

Что это означает на практике:

- `fq` включается как queue discipline по умолчанию, что нужно для корректной работы BBR.
- `bbr` включается как алгоритм TCP congestion control. Это современный congestion control от Google, который обычно даёт лучшую утилизацию канала и более стабильную задержку по сравнению с классическими алгоритмами на ряде VPN-нагрузок.
- `ip_forward=1` и `forwarding=1` включают маршрутизацию IPv4, без которой VPN-нода не сможет нормально форвардить клиентский трафик.
- `rp_filter=0` отключает strict reverse path filtering. Это важно для серверов с нестандартной маршрутизацией, policy routing, туннелями и VPN-сценариями, где слишком жёсткая проверка обратного пути может приводить к потере пакетов.
- `src_valid_mark=1` помогает корректной маршрутизации пакетов с fwmark, что часто используется WireGuard/policy routing.
- `rmem_max` и `wmem_max` увеличивают максимальные размеры receive/send buffer в ядре.
- `rmem_default` и `wmem_default` задают базовые значения буферов сокетов.
- `netdev_max_backlog=250000` увеличивает размер очереди входящих пакетов в ядре при высокой нагрузке.
- `somaxconn=32768` и `tcp_max_syn_backlog=32768` увеличивают очереди новых соединений и уменьшают вероятность кратковременных RST под всплеском нагрузки.
- `tcp_max_orphans`, `tcp_fin_timeout` и keepalive-параметры быстрее очищают зависшие TCP-сессии, не обрывая живые соединения слишком агрессивно.
- `tcp_fastopen=3` включает TCP Fast Open и для клиента, и для сервера.
- `tcp_rmem` и `tcp_wmem` расширяют диапазоны автонастройки TCP-буферов.
- `tcp_mtu_probing=1` включает MTU probing, что помогает переживать проблемы с path MTU и blackhole-сценарии.
- `nf_conntrack_*` увеличивает таблицу conntrack и сокращает слишком длинные таймауты для VPN/exit-нагрузки.

Итог: после установки сервер получает более агрессивный и практичный сетевой профиль под VPN/туннельную нагрузку, а не дефолтные conservative-настройки дистрибутива.

## NIC, RPS/RFS и fq

`vpn-node-network-tuning.service` запускается после появления сети и при каждой загрузке:

- находит основной интерфейс через default route
- включает RPS на всех доступных CPU и RFS flow table на `32768` записей
- отключает `gro` и `rx-gro-hw`, если драйвер позволяет это сделать
- ставит `fq` с `limit 100000`, `flow_limit 1000` и `buckets 8192`
- не уничтожает корневой `mq` на многоочередной NIC, а применяет `fq` отдельно к каждой TX-очереди

Настройки можно переопределить в `/etc/default/vpn-node-network-tuning`:

```bash
VPN_PRIMARY_INTERFACE=ens3
VPN_RPS_FLOW_ENTRIES=32768
VPN_DISABLE_GRO=1
VPN_FQ_LIMIT=100000
VPN_FQ_FLOW_LIMIT=1000
VPN_FQ_BUCKETS=8192
```

На качественной аппаратной NIC GRO может дать больше максимальной пропускной способности ценой более крупных пачек пакетов. В таком случае достаточно установить `VPN_DISABLE_GRO=0` и перезапустить `vpn-node-network-tuning.service`.

## 🛡 VPN defense profile

VPN defense profile выключен по умолчанию и включается отдельным интерактивным вопросом.

Если выбрать `yes`, bootstrap:

- считает RAM и CPU count
- подбирает `nf_conntrack_max`, conntrack hash buckets, `somaxconn`, `tcp_max_syn_backlog` и `netdev_max_backlog`
- пишет `/etc/sysctl.d/99-vpn-defense.conf`
- пишет `/etc/modprobe.d/vpn-defense-conntrack.conf` для conntrack hashsize после reboot
- применяет доступные sysctl сразу через `sysctl -e -p`
- создаёт или пересоздаёт chains `VPN_SYN_LIM` и `VPN_UDP_AMP`
- добавляет в `INPUT` только правила с comment `vpn-defense`
- ограничивает TCP SYN на `80,443,8443` через `hashlimit` per source IP
- ограничивает UDP amplification-поток по source ports `19,53,123,389,1900,11211,5060,1194`
- пропускает ICMP echo-request до `30/sec` burst `60`, а лишнее режет
- сохраняет firewall через `netfilter-persistent save`

## 🧬 XanMod LTS kernel

Bootstrap может опционально поставить XanMod LTS kernel. По умолчанию ответ `no`, потому что это смена ядра и она вступает в силу только после reboot.

Если XanMod выбран, bootstrap отдельно спросит, делать ли автоматический reboot после успешной установки и настройки сервера. По умолчанию auto reboot выключен.

Если выбрать `yes`, скрипт:

- проверит, что система `x86_64`
- проверит codename дистрибутива по списку, который поддерживает XanMod APT repo
- добавит `/etc/apt/keyrings/xanmod-archive-keyring.gpg`
- добавит `/etc/apt/sources.list.d/xanmod-release.list`
- определит x86-64 psABI level CPU через loader glibc
- установит один из пакетов `linux-xanmod-lts-x64v1`, `linux-xanmod-lts-x64v2` или `linux-xanmod-lts-x64v3`

XanMod LTS уместен для VPN-ноды, если нужен более свежий kernel stack, BBRv3, MGLRU и более агрессивные scheduler/network patches. Stock kernel всё равно остаётся в GRUB как fallback.

## 🧱 Как работает daily update Traffic Guard

Updater использует безопасную атомарную схему:

1. создаёт или использует активный `ipset` `blacklist`
2. создаёт уникальный временный `ipset` вида `blacklist_new_<pid>`
3. скачивает blocklist через `curl -fsSL`
4. очищает данные от пустых строк, комментариев и дублей
5. пропускает невалидные записи
6. заполняет временный set через `ipset restore`
7. выполняет `ipset swap <temp_set> blacklist`
8. удаляет временный set

Такой подход не снимает блокировку даже на короткий момент. Если загрузка, валидация или заполнение нового set завершаются ошибкой, активный `blacklist` остаётся без изменений.

Дополнительно updater берёт lock через `flock`, поэтому параллельные запуски от `systemd timer` и вручную не конфликтуют между собой.

`systemd service` ограничен capability-набором и write paths: updater получает только права, нужные для `ipset`/`iptables`, логов, lock-файла и сохранения firewall-состояния.

Для контейнерного сценария updater также восстанавливает blocklist-правила в `DOCKER-USER`, если Docker уже создал эту цепочку.

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
