#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

extract_path() {
  local name="$1"

  sed -n -E "s|^readonly ${name}=\"([^\"]+)\"$|\1|p" "${REPO_ROOT}/bootstrap.sh"
}

base_path="$(extract_path SYSCTL_TUNING_FILE)"
defense_path="$(extract_path SYSCTL_DEFENSE_FILE)"
base_name="$(basename "${base_path}")"
defense_name="$(basename "${defense_path}")"
config_file="${REPO_ROOT}/config/${base_name}"

[[ "${base_path}" == "/etc/sysctl.d/90-vpn-tuning.conf" ]] || fail "Неверный путь базового sysctl-профиля: ${base_path}"
[[ "${defense_path}" == "/etc/sysctl.d/99-vpn-defense.conf" ]] || fail "Неверный путь защитного sysctl-профиля: ${defense_path}"
[[ "${base_name}" < "${defense_name}" ]] || fail "Базовый sysctl-профиль должен применяться раньше защитного"
[[ -s "${config_file}" ]] || fail "Не найден базовый sysctl-профиль: ${config_file}"

grep -Fqx 'net.core.netdev_budget_usecs=8000' "${config_file}" || fail "Для netdev_budget_usecs ожидается совместимое значение 8000"
# shellcheck disable=SC2016
grep -Fq 'install -m 644 "${repo_root}/config/90-vpn-tuning.conf" "${SYSCTL_TUNING_FILE}"' "${REPO_ROOT}/bootstrap.sh" || fail "bootstrap.sh не устанавливает базовый sysctl-профиль"

printf 'Порядок применения sysctl-профилей корректен\n'
