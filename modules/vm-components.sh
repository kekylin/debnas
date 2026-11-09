#!/bin/bash
# @module: vm-components
# @name: 安装虚拟机组件
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 33
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

# 注释 /etc/sysctl.conf 中的生效配置
# 说明：Debian 上 /etc/sysctl.conf 经 /etc/sysctl.d/99-sysctl.conf 最后加载，
# 其中的 ip_forward 会覆盖 10-debnas-network.conf。原逻辑在文件中已有任意一行
# 注释掉的 ip_forward 时直接跳过，导致同文件中生效的那一行被保留；
# 现无条件注释所有生效行（sed 对已注释行不匹配，幂等）。
sysctl_conf="/etc/sysctl.conf"
if [ -f "$sysctl_conf" ] && grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$sysctl_conf"; then
  sed -i -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*|\1# net.ipv4.ip_forward = |' "$sysctl_conf" 2>/dev/null || true
fi

# 提示：其他排序在后的 sysctl.d 片段若把 ip_forward 设为 0，重启后仍会覆盖
for _f in /etc/sysctl.d/*.conf; do
  [[ -f "$_f" ]] || continue
  [[ "$(basename "$_f")" > "10-debnas-network.conf" ]] || continue
  [[ "$(readlink -f "$_f")" == "$(readlink -f "$sysctl_conf")" ]] && continue
  if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0' "$_f"; then
    log_warning "${_f} 将 net.ipv4.ip_forward 设为 0，重启后会覆盖本模块配置，请手动处理"
  fi
done

# 使用 sysctl_persist 实现幂等 sysctl 配置（写入 99-debnas.conf）
if sysctl_persist "net.ipv4.ip_forward" "1" "10-debnas-network.conf"; then
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
