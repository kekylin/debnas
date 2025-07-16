#!/bin/bash
# 功能：禁用 Cockpit 外网访问
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

# 删除Cockpit外网访问配置
config_file="/etc/cockpit/cockpit.conf"

if [[ -f "$config_file" ]]; then
  if grep -q "Origins" "$config_file"; then
    # 删除Origins参数行
    sed -i '/Origins/d' "$config_file"
    log_success "已删除Cockpit外网访问配置"
  else
    log_info "已检查没有配置外网访问参数，跳过操作"
  fi
else
  log_info "已跳过Cockpit外网访问配置"
fi

# 重启cockpit服务
if systemctl try-restart cockpit; then
  log_success "Cockpit服务已重启，外网访问已禁用"
else
  log_warn "Cockpit服务重启失败，请手动重启"
fi
