#!/bin/bash
# 功能：设置 Cockpit 管理网络
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
REQUIRED_CMDS=(sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 sed、systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置Cockpit接管网络配置（网络管理工具由network改为NetworkManager）
interfaces_file="/etc/network/interfaces"
nm_conf_file="/etc/NetworkManager/NetworkManager.conf"

log_info "开始配置Cockpit网络管理..."

# 注释掉/etc/network/interfaces中的内容
if [[ -f "$interfaces_file" ]]; then
  sed -i '/^[^#]/ s/^/#/' "$interfaces_file"
  log_success "已注释 $interfaces_file 中的配置"
else
  log_warn "文件 '$interfaces_file' 不存在，跳过操作"
fi

# 修改NetworkManager配置文件，将managed设置为true
if [[ -f "$nm_conf_file" ]]; then
  # 如果[ifupdown]部分不存在，添加它
  if ! grep -q '^\[ifupdown\]' "$nm_conf_file"; then
    echo -e "\n[ifupdown]\nmanaged=true" >> "$nm_conf_file"
    log_info "已添加 [ifupdown] 配置段"
  else
    # [ifupdown]存在时，替换managed行或追加
    sed -i '/^\[ifupdown\]/,/^\[/ {/^\[ifupdown\]/!{/^managed=/d}}' "$nm_conf_file" # 删除现有的managed行（如果有）
    sed -i '/^\[ifupdown\]/a managed=true' "$nm_conf_file" # 在[ifupdown]下添加managed=true
    log_info "已更新 managed 配置"
  fi
else
  log_warn "文件 '$nm_conf_file' 不存在，跳过操作"
fi

# 重启Network Manager服务
if systemctl restart NetworkManager; then
  log_success "已重启 Network Manager 服务"
else
  log_error "Network Manager 服务重启失败"
  exit "${ERROR_GENERAL}"
fi

# 重启cockpit服务
if systemctl try-restart cockpit; then
  log_success "Cockpit 网络配置完成。"
else
  log_warn "Cockpit服务重启失败，但网络配置已生效"
fi 
