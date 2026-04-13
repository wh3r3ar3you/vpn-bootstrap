#!/usr/bin/env bash

set -euo pipefail

readonly REPO_URL="https://github.com/wh3r3ar3you/vpn-bootstrap.git"
readonly DEFAULT_BRANCH="main"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf 'Run as root\n' >&2
    exit 1
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}

main() {
  trap cleanup EXIT

  require_root
  require_command git
  require_command bash

  WORKDIR="$(mktemp -d)"
  git clone --depth 1 --branch "${DEFAULT_BRANCH}" "${REPO_URL}" "${WORKDIR}/vpn-bootstrap"
  cd "${WORKDIR}/vpn-bootstrap"
  exec bash ./bootstrap.sh
}

main "$@"
