#!/bin/bash
# @module: cockpit-net
# @name: 网络管理器
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 34
# 功能：设置 Cockpit 管理网络

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查 sed、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 sed 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置 Cockpit 接管网络配置，将网络管理工具由 network 切换为 NetworkManager
interfaces_file="/etc/network/interfaces"
nm_conf_file="/etc/NetworkManager/NetworkManager.conf"
config_changed=0

log_info "配置 Cockpit 网络..."

# 先确认 NetworkManager 已安装：否则注释掉 interfaces 后无人接管网络，重启即失联
if ! command -v nmcli &>/dev/null && ! systemctl list-unit-files NetworkManager.service &>/dev/null; then
  log_warning "NetworkManager 未安装，未做任何网络配置变更"
  exit 0
fi

# 检测 ifupdown 中的静态/手动网卡配置（lo、DHCP、SLAAC 除外）
# 这类配置被注释后 NetworkManager 只会按 DHCP 接管，静态 IP 丢失导致远程失联，因此拒绝自动切换
ifupdown_files=("$interfaces_file")
for f in /etc/network/interfaces.d/*; do
  [[ -f "$f" ]] && ifupdown_files+=("$f")
done
static_ifaces=""
if [[ -f "$interfaces_file" ]]; then
  static_ifaces=$(awk '$1 == "iface" && $2 != "lo" && ($3 == "inet" || $3 == "inet6") \
    && $4 != "dhcp" && $4 != "auto" && $4 != "loopback" {print FILENAME ": " $0}' \
    "${ifupdown_files[@]}" 2>/dev/null) || static_ifaces=""
fi
if [[ -n "$static_ifaces" ]]; then
  log_error "检测到 ifupdown 静态/手动网卡配置，自动切换到 NetworkManager 会丢失静态 IP 并导致失联，已中止："
  while IFS= read -r line; do
    log_error "  ${line}"
  done <<< "$static_ifaces"
  log_info "请先用 nmcli（如 nmcli con add type ethernet ifname <网卡> ipv4.method manual ipv4.addresses <IP/掩码> ipv4.gateway <网关> ipv4.dns <DNS>）"
  log_info "或在 Cockpit 中建立等价连接，再移除上述 ifupdown 配置后重新运行本模块。"
  exit "${ERROR_GENERAL}"
fi

# 注释 /etc/network/interfaces 中的内容，避免与 NetworkManager 冲突
if [[ -f "$interfaces_file" ]]; then
  current_interfaces=$(cat "$interfaces_file")
  commented_interfaces=$(echo "$current_interfaces" | sed '/^[^#]/ s/^/#/')
  if write_file_if_changed "$interfaces_file" "$commented_interfaces"; then
    config_changed=1
    log_success "已注释 $interfaces_file 中的配置。"
  else
    log_info "$interfaces_file 无需变更。"
  fi
else
  log_warning "文件 '$interfaces_file' 不存在，跳过操作。"
fi

# 修改 NetworkManager 配置文件，确保 managed=true
if [[ -f "$nm_conf_file" ]]; then
  current_nm_config=$(cat "$nm_conf_file")
  if ! echo "$current_nm_config" | grep -q '^\[ifupdown\]'; then
    new_nm_config="$current_nm_config

[ifupdown]
managed=true"
    log_info "已添加 [ifupdown] 配置段。"
  else
    # 移除 [ifupdown] 段中的 managed= 行，然后重新插入
    new_nm_config=$(echo "$current_nm_config" | sed '/^\[ifupdown\]/,/^\[/ {/^[ifupdown]/!{/^managed=/d}}' | sed '/^\[ifupdown\]/a managed=true')
  fi
  if write_file_if_changed "$nm_conf_file" "$new_nm_config"; then
    config_changed=1
  fi
else
  log_warning "文件 '$nm_conf_file' 不存在，跳过操作。"
fi

# 仅在配置变更时重启服务
if [[ "$config_changed" -eq 1 ]]; then
  if ! service_ensure "NetworkManager" "restarted"; then
    log_error "NetworkManager 重启失败"
    exit "${ERROR_GENERAL}"
  fi
  log_success "NetworkManager 已重启"

  if service_ensure "cockpit" "restarted"; then
    log_success "Cockpit 网络就绪"
  else
    log_warning "cockpit 服务重启失败，但网络配置已生效。"
  fi
else
  log_info "配置未变更，跳过服务重启。"
fi


}

main "$@"
