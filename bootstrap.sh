#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_SSH_PORT=22
readonly BLOCKLIST_DIR="/opt/blocklists"
readonly UPDATE_SCRIPT_TARGET="/usr/local/sbin/update-traffic-guard.sh"
readonly SERVICE_TARGET="/etc/systemd/system/traffic-guard-update.service"
readonly TIMER_TARGET="/etc/systemd/system/traffic-guard-update.timer"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_BACKUP="/etc/ssh/sshd_config.bak.bootstrap"

HOSTNAME_VALUE=""
SSH_PORT_VALUE="${DEFAULT_SSH_PORT}"
SSH_KEY_VALUE=""
SSH_SERVICE_NAME=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

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

detect_ssh_service() {
  if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE_NAME="ssh"
    return
  fi

  if systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE_NAME="sshd"
    return
  fi

  printf 'Unable to detect SSH service name (ssh or sshd)\n' >&2
  exit 1
}

ask_hostname() {
  local current_hostname input
  current_hostname="$(hostnamectl --static 2>/dev/null || hostnamectl hostname 2>/dev/null || hostname)"

  while true; do
    read -r -p "Enter hostname [${current_hostname}]: " input
    input="${input:-${current_hostname}}"

    if [[ "${input}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ ]] && [[ "${input}" != *..* ]]; then
      HOSTNAME_VALUE="${input}"
      return
    fi

    printf 'Invalid hostname. Use letters, digits, dots and hyphens.\n' >&2
  done
}

ask_ssh_port() {
  local input

  while true; do
    read -r -p "Enter SSH port [${DEFAULT_SSH_PORT}]: " input
    input="${input:-${DEFAULT_SSH_PORT}}"

    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      SSH_PORT_VALUE="${input}"
      return
    fi

    printf 'Invalid SSH port. Enter a number from 1 to 65535.\n' >&2
  done
}

ask_ssh_key() {
  local input

  while true; do
    read -r -p "Enter public SSH key to add to /root/.ssh/authorized_keys: " input

    if [[ -n "${input}" ]]; then
      SSH_KEY_VALUE="${input}"
      return
    fi

    printf 'Public SSH key is required.\n' >&2
  done
}

configure_hostname() {
  local hosts_entry

  log "Configuring hostname"
  hostnamectl set-hostname "${HOSTNAME_VALUE}"

  hosts_entry="127.0.1.1 ${HOSTNAME_VALUE}"
  if grep -Eq '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    if grep -Fqx "${hosts_entry}" /etc/hosts; then
      return
    fi
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/${hosts_entry}/" /etc/hosts
  else
    printf '%s\n' "${hosts_entry}" >> /etc/hosts
  fi
}

configure_sysctl() {
  log "Configuring sysctl"

  cat <<'EOF' > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

  cat <<'EOF' > /etc/sysctl.d/99-vpn-tuning.conf

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=262144
net.core.wmem_default=262144

net.core.netdev_max_backlog=250000
net.core.somaxconn=4096

net.ipv4.tcp_fastopen=3
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
EOF

  sysctl --system >/dev/null
}

update_system() {
  log "Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
}

install_packages() {
  log "Installing required packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y \
    tcpdump \
    nload \
    iftop \
    htop \
    curl \
    sudo \
    git \
    wget \
    vim \
    zsh \
    fonts-powerline \
    ca-certificates \
    gnupg \
    lsb-release \
    ipset \
    iptables \
    iptables-persistent
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed"
  else
    log "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable --now docker
}

install_oh_my_zsh() {
  if [[ -d /root/.oh-my-zsh ]]; then
    log "Oh My Zsh is already installed"
    return
  fi

  log "Installing Oh My Zsh"
  RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

install_powerlevel10k() {
  local theme_dir="${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/themes/powerlevel10k"

  if [[ -d "${theme_dir}" ]]; then
    log "Powerlevel10k is already installed"
  else
    log "Installing Powerlevel10k"
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${theme_dir}"
  fi

  if [[ -f /root/.zshrc ]]; then
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' /root/.zshrc
  fi
}

ensure_zsh_plugin() {
  local repo_url="$1"
  local plugin_name="$2"
  local plugin_dir="${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/${plugin_name}"

  if [[ ! -d "${plugin_dir}" ]]; then
    git clone --depth=1 "${repo_url}" "${plugin_dir}"
  fi
}

configure_zsh() {
  log "Configuring Zsh"
  install_oh_my_zsh
  install_powerlevel10k

  ensure_zsh_plugin https://github.com/zsh-users/zsh-autosuggestions zsh-autosuggestions
  ensure_zsh_plugin https://github.com/zsh-users/zsh-syntax-highlighting zsh-syntax-highlighting

  if [[ -f /root/.zshrc ]]; then
    if grep -Eq '^plugins=\(' /root/.zshrc; then
      sed -i 's/^plugins=(.*/plugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)/' /root/.zshrc
    else
      printf '\nplugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)\n' >> /root/.zshrc
    fi
  fi

  if [[ "$(getent passwd root | cut -d: -f7)" != "/bin/zsh" ]]; then
    chsh -s /bin/zsh root
  fi
}

install_speedtest() {
  if dpkg -s speedtest >/dev/null 2>&1; then
    log "Speedtest is already installed"
    return
  fi

  log "Installing Speedtest"
  curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y speedtest
}

configure_authorized_keys() {
  local ssh_dir="/root/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  log "Configuring root authorized_keys"
  install -d -m 700 "${ssh_dir}"
  touch "${auth_keys}"
  chmod 600 "${auth_keys}"

  if grep -Fqx "${SSH_KEY_VALUE}" "${auth_keys}"; then
    log "Public SSH key already exists in authorized_keys"
  else
    printf '%s\n' "${SSH_KEY_VALUE}" >> "${auth_keys}"
    log "Public SSH key added to authorized_keys"
  fi
}

configure_ssh() {
  local sshd_binary tmp_file

  log "Configuring SSH daemon"
  require_command sshd
  detect_ssh_service

  cp -a "${SSHD_CONFIG}" "${SSHD_BACKUP}"
  tmp_file="$(mktemp)"
  awk -v port="${SSH_PORT_VALUE}" '
    BEGIN {
      replaced = 0
    }
    /^[[:space:]]*#?[[:space:]]*Port[[:space:]]+/ {
      if (replaced == 0) {
        print "Port " port
        replaced = 1
      }
      next
    }
    {
      print
    }
    END {
      if (replaced == 0) {
        print "Port " port
      }
    }
  ' "${SSHD_CONFIG}" > "${tmp_file}"

  chown --reference="${SSHD_CONFIG}" "${tmp_file}"
  chmod --reference="${SSHD_CONFIG}" "${tmp_file}"
  mv "${tmp_file}" "${SSHD_CONFIG}"

  sshd_binary="$(command -v sshd)"
  if ! "${sshd_binary}" -t; then
    cp -a "${SSHD_BACKUP}" "${SSHD_CONFIG}"
    printf 'sshd configuration validation failed, original config restored\n' >&2
    exit 1
  fi

  systemctl restart "${SSH_SERVICE_NAME}"
}

setup_blocklists() {
  log "Preparing blocklist directory"
  install -d -m 755 "${BLOCKLIST_DIR}"
}

install_traffic_guard_updater() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  log "Installing Traffic Guard updater"
  install -m 755 "${repo_root}/scripts/update-traffic-guard.sh" "${UPDATE_SCRIPT_TARGET}"
  install -m 644 "${repo_root}/systemd/traffic-guard-update.service" "${SERVICE_TARGET}"
  install -m 644 "${repo_root}/systemd/traffic-guard-update.timer" "${TIMER_TARGET}"

  systemctl daemon-reload
  systemctl enable --now traffic-guard-update.timer

  "${UPDATE_SCRIPT_TARGET}"
}

ensure_iptables_rule() {
  local rule=("$@")
  if ! iptables -C "${rule[@]}" >/dev/null 2>&1; then
    iptables -I "${rule[@]}"
  fi
}

apply_firewall_rules() {
  log "Applying firewall rules"

  ipset create blacklist hash:net family inet maxelem 200000 -exist

  ensure_iptables_rule INPUT -m set --match-set blacklist src -j DROP
  ensure_iptables_rule INPUT -p icmp --icmp-type echo-request -j DROP

  netfilter-persistent save >/dev/null
}

print_summary() {
  local timer_status

  timer_status="$(systemctl status traffic-guard-update.timer --no-pager --lines=6 2>/dev/null || true)"

  printf '\n===== DONE =====\n\n'
  printf 'Reconnect using:\n'
  printf 'ssh -p %s root@%s\n\n' "${SSH_PORT_VALUE}" "${HOSTNAME_VALUE}"
  printf 'Traffic Guard timer status:\n%s\n\n' "${timer_status}"
  printf 'Manual blocklist update:\n%s\n\n' "${UPDATE_SCRIPT_TARGET}"
  printf 'Then run:\n'
  printf 'p10k configure\n'
}

main() {
  require_root
  require_command hostnamectl
  require_command systemctl
  require_command apt-get

  printf '===== VPN NODE BOOTSTRAP =====\n'

  ask_hostname
  ask_ssh_port
  ask_ssh_key

  configure_hostname
  configure_sysctl
  update_system
  install_packages
  require_command curl
  require_command iptables
  require_command ipset
  install_docker
  configure_zsh
  configure_authorized_keys
  configure_ssh
  install_speedtest
  setup_blocklists
  install_traffic_guard_updater
  apply_firewall_rules
  print_summary
}

main "$@"
