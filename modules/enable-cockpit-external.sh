#!/bin/bash
# 功能：启用 Cockpit 外网访问

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖，确保 hostname、awk、sed、systemctl 已安装
REQUIRED_CMDS=(hostname awk sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 hostname、awk、sed、systemctl。"
  exit "${ERROR_DEPENDENCY}"
fi

# 读取外网访问地址，移除协议部分
read -p "Cockpit 外网访问地址（如 baidu.com 或 baidu.com:9090）：" domain
config_file="/etc/cockpit/cockpit.conf"
domain=$(echo "$domain" | sed -E 's#^https?://##')
internal_ip=$(hostname -I | awk '{print $1}')
log_info "配置 Cockpit 外网访问地址：$domain"

# 配置 Cockpit 的 Origins 参数，支持新建和更新
if [[ -f "$config_file" ]]; then
  if grep -q "Origins" "$config_file"; then
    sed -i "s#^Origins = .*#Origins = https://$domain wss://$domain https://$internal_ip:9090#" "$config_file"
    log_info "已更新 Origins 配置。"
  else
    sed -i "/\[WebService\]/a Origins = https://$domain wss://$domain https://$internal_ip:9090" "$config_file"
    log_info "已添加 Origins 配置。"
  fi
else
  echo "[WebService]" > "$config_file"
  echo "Origins = https://$domain wss://$domain https://$internal_ip:9090" >> "$config_file"
  log_info "已创建配置文件并添加 Origins 配置。"
fi

log_success "已设置 Cockpit 外网访问地址：https://$domain"

# 重启 Cockpit 服务，确保配置生效
if systemctl try-restart cockpit; then
  log_success "Cockpit 服务已重启，外网访问配置生效。"
else
  log_warn "Cockpit 服务重启失败，请手动重启。"
fi
