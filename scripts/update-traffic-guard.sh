#!/usr/bin/env bash

set -euo pipefail

readonly LOG_FILE="/var/log/traffic-guard-update.log"
readonly BLOCKLIST_DIR="/opt/blocklists"
readonly ACTIVE_SET="blacklist"
readonly TEMP_SET_PREFIX="blacklist_new"
readonly LOCK_FILE="/run/lock/traffic-guard-update.lock"
readonly IPSET_MAXELEM=500000
readonly IPSET_HASHSIZE=65536
readonly CURL_RETRY_ARGS=(--connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors)
readonly SOURCES=(
  "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
  "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
)

TEMP_SET=""

log() {
  local message="$*"
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${message}" | tee -a "${LOG_FILE}" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "Скрипт обновления необходимо запускать от root"
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "Не найдена обязательная команда: ${cmd}"
    exit 1
  fi
}

cleanup() {
  if [[ -n "${TEMP_SET}" ]]; then
    ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
  fi
}

acquire_lock() {
  install -d -m 755 /run/lock
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "Другое обновление Traffic Guard уже выполняется, выход"
    exit 0
  fi
}

init_temp_set_name() {
  TEMP_SET="${TEMP_SET_PREFIX}_$$"
}

validate_entry() {
  local entry="$1"

  ipset test "${TEMP_SET}" "${entry}" >/dev/null 2>&1 && return 0
  ipset add "${TEMP_SET}" "${entry}" -exist >/dev/null 2>&1 && {
    ipset del "${TEMP_SET}" "${entry}" >/dev/null 2>&1 || true
    return 0
  }
  return 1
}

collect_entries() {
  local source tmp_file normalized_file valid_count=0 invalid_count=0

  install -d -m 755 "${BLOCKLIST_DIR}"
  normalized_file="$(mktemp)"

  for source in "${SOURCES[@]}"; do
    tmp_file="$(mktemp)"
    log "Загружается ${source}"
    curl -fsSL "${CURL_RETRY_ARGS[@]}" "${source}" -o "${tmp_file}"
    cat "${tmp_file}" >> "${normalized_file}"
    rm -f "${tmp_file}"
  done

  awk '
    {
      gsub(/\r/, "", $0)
      sub(/[[:space:]]*#.*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "") print $0
    }
  ' "${normalized_file}" | sort -u > "${normalized_file}.sorted"

  : > "${normalized_file}.valid"

  while IFS= read -r entry; do
    if validate_entry "${entry}"; then
      printf '%s\n' "${entry}" >> "${normalized_file}.valid"
      valid_count=$((valid_count + 1))
    else
      invalid_count=$((invalid_count + 1))
      log "Некорректная запись пропущена: ${entry}"
    fi
  done < "${normalized_file}.sorted"

  if (( valid_count == 0 )); then
    rm -f "${normalized_file}" "${normalized_file}.sorted" "${normalized_file}.valid"
    log "Корректные записи не получены, текущий список блокировки оставлен без изменений"
    exit 1
  fi

  mv "${normalized_file}.valid" "${BLOCKLIST_DIR}/blacklist.current"
  rm -f "${normalized_file}" "${normalized_file}.sorted"

  log "Получено корректных записей: ${valid_count}; пропущено некорректных: ${invalid_count}"
}

populate_temp_set() {
  local count restore_file

  ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
  restore_file="$(mktemp)"
  count="$(grep -cve '^[[:space:]]*$' "${BLOCKLIST_DIR}/blacklist.current" || true)"

  if (( count == 0 )); then
    rm -f "${restore_file}"
    log "Временный набор блокировки пуст, замена отменена"
    exit 1
  fi

  {
    printf 'create %s hash:net family inet hashsize %s maxelem %s\n' "${TEMP_SET}" "${IPSET_HASHSIZE}" "${IPSET_MAXELEM}"
    awk -v set_name="${TEMP_SET}" '{ print "add " set_name " " $0 " -exist" }' "${BLOCKLIST_DIR}/blacklist.current"
  } > "${restore_file}"

  ipset restore -exist < "${restore_file}"
  rm -f "${restore_file}"

  log "Подготовлен временный набор ipset с числом записей: ${count}"
}

ensure_active_set() {
  if ! ipset list -n | grep -Fxq "${ACTIVE_SET}"; then
    ipset create "${ACTIVE_SET}" hash:net family inet hashsize "${IPSET_HASHSIZE}" maxelem "${IPSET_MAXELEM}"
    log "Создан активный набор ipset ${ACTIVE_SET}"
  fi
}

ensure_iptables_rule() {
  local rule=("$@")

  if ! iptables -C "${rule[@]}" >/dev/null 2>&1; then
    iptables -I "${rule[@]}"
    log "Добавлено отсутствующее правило iptables: ${rule[*]}"
  fi
}

ensure_docker_user_rule() {
  local rule=("$@")

  if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    return
  fi

  if ! iptables -C DOCKER-USER "${rule[@]}" >/dev/null 2>&1; then
    iptables -I DOCKER-USER "${rule[@]}"
    log "Добавлено отсутствующее правило DOCKER-USER: ${rule[*]}"
  fi
}

swap_sets() {
  ipset swap "${TEMP_SET}" "${ACTIVE_SET}"
  ipset destroy "${TEMP_SET}"
  log "Набор ${TEMP_SET} атомарно заменил ${ACTIVE_SET}"
}

ensure_firewall_rules() {
  ensure_iptables_rule INPUT -m set --match-set "${ACTIVE_SET}" src -j DROP
  ensure_iptables_rule FORWARD -m set --match-set "${ACTIVE_SET}" src -j DROP
  ensure_iptables_rule FORWARD -m set --match-set "${ACTIVE_SET}" dst -j REJECT
  ensure_iptables_rule OUTPUT -m set --match-set "${ACTIVE_SET}" dst -j REJECT
  ensure_docker_user_rule -m set --match-set "${ACTIVE_SET}" src -j DROP
  ensure_docker_user_rule -m set --match-set "${ACTIVE_SET}" dst -j REJECT
}

save_firewall_state() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null || log "Не удалось сохранить состояние через netfilter-persistent"
    return
  fi

  if command -v ipset-save >/dev/null 2>&1; then
    install -d -m 755 /etc/iptables
    ipset-save > /etc/iptables/ipsets || log "Не удалось сохранить состояние через ipset-save"
  fi
}

main() {
  trap cleanup EXIT

  require_root
  require_command curl
  require_command ipset
  require_command iptables
  require_command awk
  require_command sort
  require_command tee
  require_command flock

  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}"

  acquire_lock
  init_temp_set_name
  ensure_active_set
  ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
  ipset create "${TEMP_SET}" hash:net family inet hashsize "${IPSET_HASHSIZE}" maxelem "${IPSET_MAXELEM}"
  collect_entries
  populate_temp_set
  swap_sets
  ensure_firewall_rules
  save_firewall_state
  log "Обновление Traffic Guard успешно завершено"
}

main "$@"
