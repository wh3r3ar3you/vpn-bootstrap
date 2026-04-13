#!/usr/bin/env bash

set -euo pipefail

readonly LOG_FILE="/var/log/traffic-guard-update.log"
readonly BLOCKLIST_DIR="/opt/blocklists"
readonly ACTIVE_SET="blacklist"
readonly TEMP_SET="blacklist_new"
readonly IPTABLES_MATCH_RULE=(-m set --match-set "${ACTIVE_SET}" src -j DROP)
readonly SOURCES=(
  "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/government_networks.list"
  "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/antiscanner.list"
)

log() {
  local message="$*"
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${message}" | tee -a "${LOG_FILE}" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "This updater must run as root"
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "Required command not found: ${cmd}"
    exit 1
  fi
}

cleanup() {
  ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
}

validate_entry() {
  local entry="$1"

  if [[ "${entry}" =~ : ]]; then
    ipset test "${TEMP_SET}" "${entry}" >/dev/null 2>&1 && return 0
    ipset add "${TEMP_SET}" "${entry}" -exist >/dev/null 2>&1 && {
      ipset del "${TEMP_SET}" "${entry}" >/dev/null 2>&1 || true
      return 0
    }
    return 1
  fi

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
    log "Downloading ${source}"
    curl -fsSL "${source}" -o "${tmp_file}"
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
      log "Skipping invalid entry: ${entry}"
    fi
  done < "${normalized_file}.sorted"

  if (( valid_count == 0 )); then
    rm -f "${normalized_file}" "${normalized_file}.sorted" "${normalized_file}.valid"
    log "No valid entries collected, keeping the current blacklist unchanged"
    exit 1
  fi

  mv "${normalized_file}.valid" "${BLOCKLIST_DIR}/blacklist.current"
  rm -f "${normalized_file}" "${normalized_file}.sorted"

  log "Collected ${valid_count} valid entries, skipped ${invalid_count} invalid entries"
}

populate_temp_set() {
  local count=0

  ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
  ipset create "${TEMP_SET}" hash:net family inet maxelem 200000

  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    ipset add "${TEMP_SET}" "${entry}" -exist
    count=$((count + 1))
  done < "${BLOCKLIST_DIR}/blacklist.current"

  if (( count == 0 )); then
    log "Temporary blacklist set is empty, refusing to swap"
    exit 1
  fi

  log "Prepared temporary ipset with ${count} entries"
}

ensure_active_set() {
  if ! ipset list -n | grep -Fxq "${ACTIVE_SET}"; then
    ipset create "${ACTIVE_SET}" hash:net family inet maxelem 200000
    log "Created active ipset ${ACTIVE_SET}"
  fi
}

ensure_firewall_rule() {
  if ! iptables -C INPUT "${IPTABLES_MATCH_RULE[@]}" >/dev/null 2>&1; then
    iptables -I INPUT "${IPTABLES_MATCH_RULE[@]}"
    log "Added missing iptables DROP rule for ${ACTIVE_SET}"
  fi
}

swap_sets() {
  ipset swap "${TEMP_SET}" "${ACTIVE_SET}"
  ipset destroy "${TEMP_SET}"
  log "Atomically swapped ${TEMP_SET} into ${ACTIVE_SET}"
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

  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}"

  ensure_active_set
  ipset destroy "${TEMP_SET}" >/dev/null 2>&1 || true
  ipset create "${TEMP_SET}" hash:net family inet maxelem 200000
  collect_entries
  populate_temp_set
  swap_sets
  ensure_firewall_rule
  log "Traffic Guard update completed successfully"
}

main "$@"
