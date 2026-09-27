#!/usr/bin/env bash

set -euo pipefail

readonly CONFIG_FILE="${VPN_PANEL_ACCESS_CONFIG:-/etc/default/vpn-panel-access}"
readonly STATE_DIR="/run/vpn-panel-access"
readonly LOCK_FILE="/run/lock/vpn-panel-access.lock"
readonly CHAIN_PREFIX="VPN_PANEL_API"

PANEL_ADDRESS=""
PANEL_API_PORT=""
RESOLVE_FAILED=0
V4_ENTRIES=()
V6_ENTRIES=()

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "Скрипт доступа панели необходимо запускать от root"
    exit 1
  fi
}

acquire_lock() {
  install -d -m 755 /run/lock
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "Другое обновление доступа панели уже выполняется, выход"
    exit 0
  fi
}

is_ipv4() {
  local value="$1" octet
  local -a octets

  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || return 1
  IFS=. read -r -a octets <<< "${value%%/*}"
  for octet in "${octets[@]}"; do
    (( 10#${octet} <= 255 )) || return 1
  done
}

is_ipv6() {
  local value="$1"

  [[ "${value}" == *:* ]] || return 1
  [[ "${value}" =~ ^[0-9A-Fa-f:.]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]
}

is_domain() {
  local value="$1"

  [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\.?$ ]]
}

ipv6_firewall_available() {
  command -v ip6tables >/dev/null 2>&1 && ip6tables -nL INPUT >/dev/null 2>&1
}

resolve_domain() {
  local domain="$1" address found=0

  while read -r address _; do
    V4_ENTRIES+=("${address}")
    found=1
  done < <(getent ahostsv4 "${domain}" 2>/dev/null | awk '$2 == "STREAM"' || true)

  if ipv6_firewall_available; then
    while read -r address _; do
      V6_ENTRIES+=("${address}")
      found=1
    done < <(getent ahostsv6 "${domain}" 2>/dev/null | awk '$2 == "STREAM" && $1 ~ /:/ && $1 !~ /^::ffff:/' || true)
  fi

  if (( found == 0 )); then
    log "Не удалось разрешить домен панели: ${domain}"
    RESOLVE_FAILED=1
  fi
}

collect_entries() {
  local token

  for token in ${PANEL_ADDRESS//,/ }; do
    if is_ipv4 "${token}"; then
      V4_ENTRIES+=("${token}")
    elif is_ipv6 "${token}"; then
      V6_ENTRIES+=("${token}")
    elif is_domain "${token}"; then
      resolve_domain "${token%.}"
    else
      log "Некорректный адрес панели пропущен: ${token}"
      RESOLVE_FAILED=1
    fi
  done
}

active_chain() {
  local bin="$1"

  "${bin}" -S INPUT 2>/dev/null \
    | awk -v prefix="${CHAIN_PREFIX}_" '$1 == "-A" && $NF ~ ("^" prefix "[AB]$") { print $NF; exit }'
}

delete_jumps_except() {
  local bin="$1" keep_chain="$2" rule_spec

  while read -r rule_spec; do
    [[ -n "${rule_spec}" ]] || continue
    # shellcheck disable=SC2086
    "${bin}" -D ${rule_spec#-A } 2>/dev/null || true
  done < <(
    "${bin}" -S INPUT 2>/dev/null \
      | awk -v prefix="${CHAIN_PREFIX}_" -v keep="${keep_chain}" \
        '$1 == "-A" && $NF ~ ("^" prefix "[AB]$") && $NF != keep'
  )
}

remove_chain() {
  local bin="$1" chain="$2"

  "${bin}" -F "${chain}" >/dev/null 2>&1 || true
  "${bin}" -X "${chain}" >/dev/null 2>&1 || true
}

# Собирает новую цепочку рядом с активной, переключает на неё переход из
# INPUT и только после этого удаляет старую: порт не остаётся открытым ни
# на мгновение.
apply_family() {
  local bin="$1"
  shift
  local current next entry

  current="$(active_chain "${bin}")"
  if [[ "${current}" == "${CHAIN_PREFIX}_A" ]]; then
    next="${CHAIN_PREFIX}_B"
  else
    next="${CHAIN_PREFIX}_A"
  fi

  remove_chain "${bin}" "${next}"
  "${bin}" -N "${next}"
  "${bin}" -A "${next}" -i lo -j ACCEPT
  for entry in "$@"; do
    "${bin}" -A "${next}" -s "${entry}" -j ACCEPT
  done
  "${bin}" -A "${next}" -j DROP

  "${bin}" -I INPUT 1 -p tcp -m tcp --dport "${PANEL_API_PORT}" -j "${next}"
  delete_jumps_except "${bin}" "${next}"
  if [[ -n "${current}" ]]; then
    remove_chain "${bin}" "${current}"
  fi
}

remove_family() {
  local bin="$1"

  delete_jumps_except "${bin}" ""
  remove_chain "${bin}" "${CHAIN_PREFIX}_A"
  remove_chain "${bin}" "${CHAIN_PREFIX}_B"
}

save_firewall_state() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || log "Не удалось сохранить правила через netfilter-persistent"
  fi
}

signature() {
  printf 'port=%s\nv4=%s\nv6=%s\n' "${PANEL_API_PORT}" \
    "$(printf '%s\n' "${V4_ENTRIES[@]}" | sort -u | tr '\n' ' ')" \
    "$(printf '%s\n' "${V6_ENTRIES[@]}" | sort -u | tr '\n' ' ')"
}

main() {
  local state_file="${STATE_DIR}/applied" new_signature v4_unique=() v6_unique=()

  require_root
  acquire_lock
  install -d -m 755 "${STATE_DIR}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  if [[ -z "${PANEL_ADDRESS}" || -z "${PANEL_API_PORT}" ]]; then
    log "Адрес панели или порт API не заданы, ограничение доступа снимается"
    remove_family iptables
    ipv6_firewall_available && remove_family ip6tables
    rm -f "${state_file}"
    save_firewall_state
    exit 0
  fi

  if ! [[ "${PANEL_API_PORT}" =~ ^[0-9]+$ ]] || (( PANEL_API_PORT < 1 || PANEL_API_PORT > 65535 )); then
    log "Некорректный порт API: ${PANEL_API_PORT}"
    exit 1
  fi

  collect_entries

  # При сбое DNS оставляем уже действующие правила: панель продолжит
  # работать по старым адресам, а порт останется закрытым для остальных.
  if (( RESOLVE_FAILED == 1 )) && [[ -n "$(active_chain iptables)" ]]; then
    log "Адреса панели получены не полностью, текущие правила оставлены без изменений"
    exit 1
  fi

  if [[ ${#V4_ENTRIES[@]} -gt 0 ]]; then
    mapfile -t v4_unique < <(printf '%s\n' "${V4_ENTRIES[@]}" | sort -u)
  fi
  if [[ ${#V6_ENTRIES[@]} -gt 0 ]]; then
    mapfile -t v6_unique < <(printf '%s\n' "${V6_ENTRIES[@]}" | sort -u)
  fi
  V4_ENTRIES=("${v4_unique[@]}")
  V6_ENTRIES=("${v6_unique[@]}")

  new_signature="$(signature)"
  if [[ -f "${state_file}" && "$(cat "${state_file}")" == "${new_signature}" && -n "$(active_chain iptables)" ]] \
    && { ! ipv6_firewall_available || [[ -n "$(active_chain ip6tables)" ]]; }; then
    exit 0
  fi

  apply_family iptables "${V4_ENTRIES[@]}"
  if ipv6_firewall_available; then
    apply_family ip6tables "${V6_ENTRIES[@]}"
  fi

  printf '%s' "${new_signature}" > "${state_file}"
  save_firewall_state

  log "Порт API ${PANEL_API_PORT}/tcp открыт только для панели: IPv4 [${V4_ENTRIES[*]:-нет}] IPv6 [${V6_ENTRIES[*]:-нет}]"

  if (( RESOLVE_FAILED == 1 )); then
    exit 1
  fi
}

main "$@"
