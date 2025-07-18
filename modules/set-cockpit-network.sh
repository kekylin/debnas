#!/bin/bash
# 功能：设置 Cockpit 管理网络

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 sed、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 sed 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置 Cockpit 接管网络配置，将网络管理工具由 network 切换为 NetworkManager
interfaces_file="/etc/network/interfaces"
nm_conf_file="/etc/NetworkManager/NetworkManager.conf"

log_info "开始配置 Cockpit 网络管理..."

# 注释 /etc/network/interfaces 中的内容，避免与 NetworkManager 冲突
if [[ -f "$interfaces_file" ]]; then
  sed -i '/^[^#]/ s/^/#/' "$interfaces_file"
  log_success "已注释 $interfaces_file 中的配置。"
else
  log_warn "文件 '$interfaces_file' 不存在，跳过操作。"
fi

# 修改 NetworkManager 配置文件，确保 managed=true
if [[ -f "$nm_conf_file" ]]; then
  if ! grep -q '^\[ifupdown\]' "$nm_conf_file"; then
    echo -e "\n[ifupdown]\nmanaged=true" >> "$nm_conf_file"
    log_info "已添加 [ifupdown] 配置段。"
  else
    sed -i '/^\[ifupdown\]/,/^\[/ {/^[ifupdown]/!{/^managed=/d}}' "$nm_conf_file"
    sed -i '/^\[ifupdown\]/a managed=true' "$nm_conf_file"
    log_info "已更新 managed 配置。"
  fi
else
  log_warn "文件 '$nm_conf_file' 不存在，跳过操作。"
fi

# 重启 NetworkManager 服务，确保配置生效
if systemctl restart NetworkManager; then
  log_success "已重启 NetworkManager 服务。"
else
  log_error "NetworkManager 服务重启失败。"
  exit "${ERROR_GENERAL}"
fi

# 重启 cockpit 服务，确保网络管理功能生效
if systemctl try-restart cockpit; then
  log_success "Cockpit 网络配置完成。"
else
  log_warn "cockpit 服务重启失败，但网络配置已生效。"
fi 
