#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEST_DIR REPO_ROOT

cleanup() {
  rm -rf "${TEST_DIR}"
}

assert_equal() {
  local expected="$1"
  local actual="$2"

  if [[ "${expected}" != "${actual}" ]]; then
    printf 'Ожидалось: %s; получено: %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
}

trap cleanup EXIT

mkdir -p "${TEST_DIR}/sys/class/net/ens3/device" "${TEST_DIR}/sys/class/net/ens4" "${TEST_DIR}/sys/bus/virtio/drivers/virtio_net"
ln -s "${TEST_DIR}/sys/bus/virtio/drivers/virtio_net" "${TEST_DIR}/sys/class/net/ens3/device/driver"

export VPN_SYSFS_NET_ROOT="${TEST_DIR}/sys/class/net"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/apply-vpn-network-tuning.sh"

assert_equal virtio_net "$(detect_nic_driver ens3)"
is_virtio_driver virtio_net
if is_virtio_driver vmxnet3; then
  printf 'vmxnet3 ошибочно определён как virtio\n' >&2
  exit 1
fi

ethtool() {
  printf 'driver: vmxnet3\n'
}

assert_equal vmxnet3 "$(detect_nic_driver ens4)"

printf 'Автоопределение virtio работает\n'
