#!/usr/bin/env bash

set -euo pipefail

VPN_PRIMARY_INTERFACE="${VPN_PRIMARY_INTERFACE:-}"
VPN_RPS_FLOW_ENTRIES="${VPN_RPS_FLOW_ENTRIES:-32768}"
VPN_DISABLE_GRO="${VPN_DISABLE_GRO:-auto}"
VPN_FQ_LIMIT="${VPN_FQ_LIMIT:-100000}"
VPN_FQ_FLOW_LIMIT="${VPN_FQ_FLOW_LIMIT:-1000}"
VPN_FQ_BUCKETS="${VPN_FQ_BUCKETS:-8192}"
VPN_SYSFS_NET_ROOT="${VPN_SYSFS_NET_ROOT:-/sys/class/net}"

log() {
  printf '[настройка-сети-vpn] %s\n' "$*"
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    printf '%s должно быть положительным целым числом, получено: %s\n' "${name}" "${value}" >&2
    exit 1
  fi
}

require_gro_mode() {
  case "${VPN_DISABLE_GRO}" in
    auto|0|1)
      return
      ;;
  esac

  printf 'VPN_DISABLE_GRO должен иметь значение auto, 0 или 1; получено: %s\n' "${VPN_DISABLE_GRO}" >&2
  exit 1
}

detect_primary_interface() {
  local iface

  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '
    /dev/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  ')"

  if [[ -n "${iface}" ]]; then
    printf '%s\n' "${iface}"
    return
  fi

  ip -br link 2>/dev/null | awk '$1 !~ /^(lo|docker|veth|br-|tun|tap|wg)/ && $2 == "UP" { print $1; exit }'
}

detect_nic_driver() {
  local iface="$1"
  local driver_path driver

  driver_path="$(readlink -f "${VPN_SYSFS_NET_ROOT}/${iface}/device/driver" 2>/dev/null || true)"
  if [[ -n "${driver_path}" ]]; then
    basename "${driver_path}"
    return
  fi

  driver="$(ethtool -i "${iface}" 2>/dev/null | awk -F ': ' '$1 == "driver" { print $2; exit }')"
  printf '%s\n' "${driver:-неизвестен}"
}

is_virtio_driver() {
  case "$1" in
    virtio|virtio_net|virtio-net)
      return 0
      ;;
  esac

  return 1
}

build_cpu_mask() {
  local cpus="$1"
  local full_chunks remainder i
  local chunks=()

  full_chunks=$(( cpus / 32 ))
  remainder=$(( cpus % 32 ))

  if (( remainder > 0 )); then
    chunks+=("$(printf '%x' "$(( (1 << remainder) - 1 ))")")
  fi

  for (( i = 0; i < full_chunks; i++ )); do
    chunks+=("ffffffff")
  done

  (IFS=,; printf '%s\n' "${chunks[*]}")
}

apply_rps_rfs() {
  local iface="$1"
  local cpu_count cpu_mask queue_count per_queue queue
  local rps_cpu_files=()
  local rps_flow_files=()

  cpu_count="$(nproc)"
  if (( cpu_count <= 1 )); then
    log "RPS/RFS пропущен на одноядерной ноде"
    return
  fi

  shopt -s nullglob
  rps_cpu_files=("${VPN_SYSFS_NET_ROOT}"/"${iface}"/queues/rx-*/rps_cpus)
  rps_flow_files=("${VPN_SYSFS_NET_ROOT}"/"${iface}"/queues/rx-*/rps_flow_cnt)
  shopt -u nullglob

  if (( ${#rps_cpu_files[@]} == 0 || ${#rps_flow_files[@]} == 0 )); then
    log "RPS/RFS пропущен: интерфейс ${iface} не предоставляет настраиваемых очередей приёма"
    return
  fi

  cpu_mask="$(build_cpu_mask "${cpu_count}")"
  queue_count="${#rps_flow_files[@]}"
  per_queue=$(( VPN_RPS_FLOW_ENTRIES / queue_count ))
  (( per_queue >= 1 )) || per_queue=1

  for queue in "${rps_cpu_files[@]}"; do
    [[ -w "${queue}" ]] && printf '%s\n' "${cpu_mask}" > "${queue}"
  done

  printf '%s\n' "${VPN_RPS_FLOW_ENTRIES}" > /proc/sys/net/core/rps_sock_flow_entries

  for queue in "${rps_flow_files[@]}"; do
    [[ -w "${queue}" ]] && printf '%s\n' "${per_queue}" > "${queue}"
  done

  log "RPS/RFS включён на ${iface}: ядра=${cpu_count} маска=${cpu_mask} потоки=${VPN_RPS_FLOW_ENTRIES}/${per_queue}"
}

configure_gro() {
  local iface="$1"
  local driver="$2"
  local disable_gro=0

  case "${VPN_DISABLE_GRO}" in
    auto)
      if is_virtio_driver "${driver}"; then
        disable_gro=1
        log "Обнаружен virtio: GRO будет отключён для стабильности"
      else
        log "GRO оставлен без изменений: драйвер ${driver} не относится к virtio"
      fi
      ;;
    1)
      disable_gro=1
      log "Отключение GRO принудительно включено в конфигурации"
      ;;
    0)
      log "Изменение GRO принудительно отключено в конфигурации"
      ;;
    *)
      printf 'VPN_DISABLE_GRO должен иметь значение auto, 0 или 1; получено: %s\n' "${VPN_DISABLE_GRO}" >&2
      exit 1
      ;;
  esac

  (( disable_gro == 1 )) || return

  if ethtool -K "${iface}" gro off >/dev/null 2>&1; then
    log "GRO отключён на ${iface}"
  else
    log "Не удалось изменить GRO на ${iface}; настройка продолжается"
  fi

  ethtool -K "${iface}" rx-gro-hw off >/dev/null 2>&1 || true
}

replace_fq() {
  local iface="$1"
  shift

  if tc qdisc replace dev "${iface}" "$@" fq \
    limit "${VPN_FQ_LIMIT}" \
    flow_limit "${VPN_FQ_FLOW_LIMIT}" \
    buckets "${VPN_FQ_BUCKETS}" 2>/dev/null; then
    return
  fi

  tc qdisc replace dev "${iface}" "$@" fq \
    limit "${VPN_FQ_LIMIT}" \
    flow_limit "${VPN_FQ_FLOW_LIMIT}"
}

apply_fq() {
  local iface="$1"
  local root_kind parent
  local tx_queues=()
  local parents=()

  shopt -s nullglob
  tx_queues=("${VPN_SYSFS_NET_ROOT}"/"${iface}"/queues/tx-*)
  shopt -u nullglob

  if (( ${#tx_queues[@]} <= 1 )); then
    replace_fq "${iface}" root
    log "Расширенный fq установлен как корневая очередь на ${iface}"
    return
  fi

  root_kind="$(tc qdisc show dev "${iface}" | awk '$4 == "root" { print $2; exit }')"
  if [[ "${root_kind}" != "mq" ]]; then
    log "Корневая очередь ${root_kind:-неизвестно} сохранена на многоочередном интерфейсе ${iface}"
    return
  fi

  mapfile -t parents < <(tc qdisc show dev "${iface}" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "parent") print $(i + 1)
      }
    }
  ' | sort -u)

  for parent in "${parents[@]}"; do
    replace_fq "${iface}" parent "${parent}"
  done

  log "Расширенный fq установлен на ${#parents[@]} аппаратных очередях передачи интерфейса ${iface}"
}

main() {
  local driver iface

  require_positive_integer VPN_RPS_FLOW_ENTRIES "${VPN_RPS_FLOW_ENTRIES}"
  require_positive_integer VPN_FQ_LIMIT "${VPN_FQ_LIMIT}"
  require_positive_integer VPN_FQ_FLOW_LIMIT "${VPN_FQ_FLOW_LIMIT}"
  require_positive_integer VPN_FQ_BUCKETS "${VPN_FQ_BUCKETS}"
  require_gro_mode

  iface="${VPN_PRIMARY_INTERFACE:-$(detect_primary_interface)}"
  if [[ -z "${iface}" || ! -d "${VPN_SYSFS_NET_ROOT}/${iface}" ]]; then
    printf 'Не удалось определить основной сетевой интерфейс\n' >&2
    exit 1
  fi

  driver="$(detect_nic_driver "${iface}")"
  log "Основной интерфейс: ${iface}; драйвер: ${driver}"

  apply_rps_rfs "${iface}"
  configure_gro "${iface}" "${driver}"
  apply_fq "${iface}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
