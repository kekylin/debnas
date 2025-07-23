#!/bin/bash
# 功能：安装虚拟机组件

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 apt、awk、sysctl、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(apt awk sysctl systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 apt、awk、sysctl 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 获取系统版本代号，便于后续安装 backports 组件
os_codename=$(awk -F= '/VERSION_CODENAME/{print $2}' /etc/os-release)

# 安装 cockpit-machines 组件，增强虚拟化管理能力
log_info "安装 cockpit-machines 组件..."
if ! apt install -y -t "$os_codename-backports" cockpit-machines; then
  log_error "cockpit-machines 组件安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 开启 IP 包转发功能，保障虚拟机网络互通
log_info "开启 IP 包转发功能..."
sysctl_conf="/etc/sysctl.conf"
if grep -qE "^#?net.ipv4.ip_forward=1" "$sysctl_conf"; then
  sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' "$sysctl_conf"
  log_info "已启用 IP 包转发配置。"
else
  echo "net.ipv4.ip_forward=1" >> "$sysctl_conf"
  log_info "已添加 IP 包转发配置。"
fi

if sysctl -p; then
  log_success "IP 包转发功能已启用。"
else
  log_warning "IP 包转发配置应用失败，请手动检查。"
fi

# 重启 cockpit 服务，确保新组件生效
if systemctl try-restart cockpit; then
  log_success "已安装虚拟机组件并重启 cockpit 服务。"
else
  log_warning "cockpit 服务重启失败，但虚拟机组件已安装。"
fi
