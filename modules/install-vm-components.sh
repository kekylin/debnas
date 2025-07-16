#!/bin/bash
# 功能：安装虚拟机组件
# 参数：无（可根据需要扩展）
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖
REQUIRED_CMDS=(apt awk sysctl systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 apt、awk、sysctl、systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 获取系统版本代号
os_codename=$(awk -F= '/VERSION_CODENAME/{print $2}' /etc/os-release)

# 安装 cockpit-machines 组件
log_info "安装 cockpit-machines 组件..."
if ! apt install -y -t "$os_codename-backports" cockpit-machines; then
  log_error "cockpit-machines 组件安装失败"
  exit "${ERROR_GENERAL}"
fi

# 开启IP包转发功能
log_info "开启IP包转发功能..."
sysctl_conf="/etc/sysctl.conf"
if grep -qE "^#?net.ipv4.ip_forward=1" "$sysctl_conf"; then
  sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' "$sysctl_conf"
  log_info "已启用IP包转发配置"
else
  echo "net.ipv4.ip_forward=1" >> "$sysctl_conf"
  log_info "已添加IP包转发配置"
fi

if sysctl -p; then
  log_success "IP包转发功能已启用"
else
  log_warn "IP包转发配置应用失败，请手动检查"
fi

# 重启cockpit服务
if systemctl try-restart cockpit; then
  log_success "已安装虚拟机组件并重启cockpit服务"
else
  log_warn "cockpit服务重启失败，但虚拟机组件已安装"
fi
