#!/bin/bash
# @module: vm-components
# @name: 虚拟机组件
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 31
# 功能：安装虚拟机管理组件

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 获取系统版本代号
SYSTEM_CODENAME=$(get_system_codename)
if [ -z "$SYSTEM_CODENAME" ]; then
  exit "${ERROR_GENERAL}"
fi

# 检查并配置 Cockpit Pinning
if ! check_pinning_status "/etc/apt/preferences.d/cockpit-backports.pref"; then
  log_info "配置 Cockpit Pinning..."
  if ! configure_cockpit_pinning "${SYSTEM_CODENAME}"; then
    log_error "Cockpit APT Pinning 配置失败。"
    exit "${ERROR_GENERAL}"
  fi
  
  # 应用 APT Pinning 配置
  if ! apply_pinning_config; then
    log_error "APT Pinning 配置应用失败。"
    exit "${ERROR_GENERAL}"
  fi
fi

# 安装 cockpit-machines 组件（智能过滤已安装包）
log_info "安装 cockpit-machines 组件..."
if ! apt_install_packages cockpit-machines; then
  log_error "cockpit-machines 组件安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 启用 IP 包转发功能（幂等）
log_info "启用 IP 包转发功能..."

# 注释 /etc/sysctl.conf 中的重复配置
sysctl_conf="/etc/sysctl.conf"
if [ -f "$sysctl_conf" ]; then
  if grep -nEq '^[[:space:]]*#[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*' "$sysctl_conf"; then
    :
  elif grep -nEq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*.*$' "$sysctl_conf"; then
    sed -i -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*|\1# net.ipv4.ip_forward = |' "$sysctl_conf" 2>/dev/null || true
    sed -i -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=|\1# net.ipv4.ip_forward =|' "$sysctl_conf" 2>/dev/null || true
  fi
fi

# 使用 sysctl_persist 实现幂等 sysctl 配置（写入 99-debnas.conf）
if sysctl_persist "net.ipv4.ip_forward" "1" "99-debnas.conf"; then
  log_success "IP 包转发功能已启用。"
else
  log_warning "IP 包转发配置已写入，但应用失败，请手动执行：systemctl restart systemd-sysctl.service"
fi

# 重启 cockpit 服务使新组件生效
if service_ensure "cockpit" "restarted"; then
  log_success "虚拟机组件 就绪"
else
  log_warning "cockpit 服务重启失败，但虚拟机组件已安装。"
fi


}

main "$@"
