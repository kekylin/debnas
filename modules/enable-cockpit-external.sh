#!/bin/bash
# 功能：启用 Cockpit 外网访问
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
REQUIRED_CMDS=(hostname awk sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 hostname、awk、sed、systemctl"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置Cockpit外网访问
read -p "Cockpit外网访问地址，如有端口号需一并输入【例如： baidu.com 或 baidu.com:9090 】请输入： " domain

config_file="/etc/cockpit/cockpit.conf"

# 移除输入中的协议部分
domain=$(echo "$domain" | sed -E 's#^https?://##')

# 提取当前主机内网IP地址
internal_ip=$(hostname -I | awk '{print $1}')

log_info "配置Cockpit外网访问地址：$domain"

# 配置Cockpit的Origins参数
if [[ -f "$config_file" ]]; then
  if grep -q "Origins" "$config_file"; then
    sed -i "s#^Origins = .*#Origins = https://$domain wss://$domain https://$internal_ip:9090#" "$config_file"
    log_info "已更新Origins配置"
  else
    sed -i "/\[WebService\]/a Origins = https://$domain wss://$domain https://$internal_ip:9090" "$config_file"
    log_info "已添加Origins配置"
  fi
else
  echo "[WebService]" > "$config_file"
  echo "Origins = https://$domain wss://$domain https://$internal_ip:9090" >> "$config_file"
  log_info "已创建配置文件并添加Origins配置"
fi

log_success "已设置Cockpit外网访问地址：https://$domain"

# 重启cockpit服务
if systemctl try-restart cockpit; then
  log_success "Cockpit服务已重启，外网访问配置生效"
else
  log_warn "Cockpit服务重启失败，请手动重启"
fi
