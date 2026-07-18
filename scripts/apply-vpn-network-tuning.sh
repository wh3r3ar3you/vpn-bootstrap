#!/usr/bin/env bash

set -euo pipefail

VPN_PRIMARY_INTERFACE="${VPN_PRIMARY_INTERFACE:-}"
VPN_RPS_FLOW_ENTRIES="${VPN_RPS_FLOW_ENTRIES:-32768}"
VPN_DISABLE_GRO="${VPN_DISABLE_GRO:-1}"
VPN_FQ_LIMIT="${VPN_FQ_LIMIT:-100000}"
VPN_FQ_FLOW_LIMIT="${VPN_FQ_FLOW_LIMIT:-1000}"
VPN_FQ_BUCKETS="${VPN_FQ_BUCKETS:-8192}"

log() {
  printf '[vpn-network-tuning] %s\n' "$*"
}

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    printf '%s must be a positive integer, got: %s\n' "${name}" "${value}" >&2
    exit 1
  fi
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
    log "RPS/RFS skipped on a single-CPU node"
    return
  fi

  shopt -s nullglob
  rps_cpu_files=(/sys/class/net/"${iface}"/queues/rx-*/rps_cpus)
  rps_flow_files=(/sys/class/net/"${iface}"/queues/rx-*/rps_flow_cnt)
  shopt -u nullglob

  if (( ${#rps_cpu_files[@]} == 0 || ${#rps_flow_files[@]} == 0 )); then
    log "RPS/RFS skipped: ${iface} exposes no configurable RX queues"
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

  log "RPS/RFS enabled on ${iface}: CPUs=${cpu_count} mask=${cpu_mask} flows=${VPN_RPS_FLOW_ENTRIES}/${per_queue}"
}

disable_gro() {
  local iface="$1"

  if [[ "${VPN_DISABLE_GRO}" != "1" ]]; then
    log "GRO override disabled by configuration"
    return
  fi

  if ethtool -K "${iface}" gro off >/dev/null 2>&1; then
    log "GRO disabled on ${iface}"
  else
    log "GRO could not be changed on ${iface}; continuing"
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
  tx_queues=(/sys/class/net/"${iface}"/queues/tx-*)
  shopt -u nullglob

  if (( ${#tx_queues[@]} <= 1 )); then
    replace_fq "${iface}" root
    log "Expanded fq installed as the root qdisc on ${iface}"
    return
  fi

  root_kind="$(tc qdisc show dev "${iface}" | awk '$4 == "root" { print $2; exit }')"
  if [[ "${root_kind}" != "mq" ]]; then
    log "Preserving ${root_kind:-unknown} root qdisc on multi-queue interface ${iface}"
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

  log "Expanded fq installed on ${#parents[@]} hardware TX queues of ${iface}"
}

main() {
  local iface

  require_positive_integer VPN_RPS_FLOW_ENTRIES "${VPN_RPS_FLOW_ENTRIES}"
  require_positive_integer VPN_FQ_LIMIT "${VPN_FQ_LIMIT}"
  require_positive_integer VPN_FQ_FLOW_LIMIT "${VPN_FQ_FLOW_LIMIT}"
  require_positive_integer VPN_FQ_BUCKETS "${VPN_FQ_BUCKETS}"

  iface="${VPN_PRIMARY_INTERFACE:-$(detect_primary_interface)}"
  if [[ -z "${iface}" || ! -d "/sys/class/net/${iface}" ]]; then
    printf 'Unable to detect the primary network interface\n' >&2
    exit 1
  fi

  apply_rps_rfs "${iface}"
  disable_gro "${iface}"
  apply_fq "${iface}"
}

main "$@"
