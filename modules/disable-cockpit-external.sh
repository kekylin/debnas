#!/bin/bash
# 功能：禁用 Cockpit 外网访问

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖，确保 sed、systemctl 已安装
REQUIRED_CMDS=(sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 sed、systemctl。"
  exit "${ERROR_DEPENDENCY}"
fi

# 删除 Cockpit 外网访问配置，提升安全性
config_file="/etc/cockpit/cockpit.conf"
if [[ -f "$config_file" ]]; then
  if grep -q "Origins" "$config_file"; then
    sed -i '/Origins/d' "$config_file"
    log_success "已删除 Cockpit 外网访问配置。"
  else
    log_info "未检测到外网访问参数，跳过操作。"
  fi
else
  log_info "未检测到 Cockpit 配置文件，跳过操作。"
fi

# 重启 Cockpit 服务，确保配置生效
if systemctl try-restart cockpit; then
  log_success "Cockpit 服务已重启，外网访问已禁用。"
else
  log_warn "Cockpit 服务重启失败，请手动重启。"
fi
