#!/bin/bash
# 功能：安装虚拟机管理组件

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/apt-pinning.sh"

# 获取系统版本代号
SYSTEM_CODENAME=$(get_system_codename)
if [ -z "$SYSTEM_CODENAME" ]; then
  exit "${ERROR_GENERAL}"
fi

# 检查并配置 Cockpit Pinning
if ! check_pinning_status "/etc/apt/preferences.d/cockpit-backports.pref"; then
  log_info "检测到未配置 Cockpit Pinning，正在配置..."
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

# 安装 cockpit-machines 组件
log_info "安装 cockpit-machines 组件..."
if ! apt install -y cockpit-machines; then
  log_error "cockpit-machines 组件安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 启用 IP 包转发功能
log_info "启用 IP 包转发功能..."
sysctl_dir="/etc/sysctl.d"
sysctl_conf="/etc/sysctl.d/99-debnas.conf"

mkdir -p "$sysctl_dir"
touch "$sysctl_conf"
chmod 644 "$sysctl_conf"

# 注释 /etc/sysctl.conf 中的重复配置
if [ -f /etc/sysctl.conf ]; then
  if grep -nEq '^[[:space:]]*#[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*' /etc/sysctl.conf; then
    :
  elif grep -nEq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*.*$' /etc/sysctl.conf; then
    sed -i -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*|\1# net.ipv4.ip_forward = |' /etc/sysctl.conf 2>/dev/null || true
    sed -i -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=|\1# net.ipv4.ip_forward =|' /etc/sysctl.conf 2>/dev/null || true
  fi
fi

# 移除重复配置并添加新配置
sed -i '/^net\.ipv4\.ip_forward\s*=\s*/d' "$sysctl_conf" 2>/dev/null || true
echo "net.ipv4.ip_forward = 1" >> "$sysctl_conf"

# 应用 sysctl 配置
if systemctl restart systemd-sysctl.service; then
  log_success "IP 包转发功能已启用。"
else
  log_warning "IP 包转发配置已写入 $sysctl_conf，但应用失败，请手动执行：systemctl restart systemd-sysctl.service"
fi

# 重启 cockpit 服务使新组件生效
if systemctl try-restart cockpit; then
  log_success "已安装虚拟机组件并重启 cockpit 服务。"
else
  log_warning "cockpit 服务重启失败，但虚拟机组件已安装。"
fi

log_success "虚拟机管理组件安装完成"
