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
    log_debug "NetworkManager [ifupdown] managed 配置已更新"
  fi
  if write_file_if_changed "$nm_conf_file" "$new_nm_config"; then
    config_changed=1
  fi
else
  log_warning "文件 '$nm_conf_file' 不存在，跳过操作。"
fi

# 检查 NetworkManager 是否安装
if ! command -v nmcli &>/dev/null && ! systemctl list-unit-files NetworkManager.service &>/dev/null; then
  log_warning "NetworkManager 未安装"
  exit 0
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
