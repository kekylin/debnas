#!/bin/bash
# @module: cockpit-ext-on
# @name: 外网访问（开）
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 32
# 功能：启用 Cockpit 外网访问

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查依赖，确保 hostname、awk、sed、systemctl 已安装
REQUIRED_CMDS=(hostname awk sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 hostname、awk、sed、systemctl。"
  exit "${ERROR_DEPENDENCY}"
fi

# 读取外网访问地址，移除协议部分并验证输入
read -r -p "Cockpit 外网访问地址（如 baidu.com 或 baidu.com:9090）：" domain
config_file="/etc/cockpit/cockpit.conf"
domain="${domain#http://}"
domain="${domain#https://}"
domain="${domain%%/*}"

# 验证域名输入：非空且仅包含合法字符（字母、数字、点、连字符、冒号）
if [[ -z "$domain" ]]; then
  log_error "域名不能为空，请重新执行并输入有效地址。"
  exit "${ERROR_PARAMETER}"
fi
if [[ ! "$domain" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
  log_error "域名格式无效：${domain}，仅允许字母、数字、点、连字符和冒号。"
  exit "${ERROR_PARAMETER}"
fi

internal_ip=$(hostname -I | awk '{print $1}')
log_info "配置 Cockpit 外网访问地址：$domain"

# 配置 Cockpit 的 Origins 参数（在内存中构建完整内容，使用 write_file_if_changed 写入）
origins_line="Origins = https://$domain wss://$domain https://$internal_ip:9090"
new_config=""

if [[ -f "$config_file" ]]; then
  current_config=$(cat "$config_file")
  if echo "$current_config" | grep -q "Origins"; then
    # 替换已有 Origins 行
    new_config=$(echo "$current_config" | sed "s#^Origins = .*#$origins_line#")
  else
    # 在 [WebService] 段后插入 Origins 行
    if echo "$current_config" | grep -q '\[WebService\]'; then
      new_config=$(echo "$current_config" | sed "/\[WebService\]/a $origins_line")
    else
      new_config="$current_config

[WebService]
$origins_line"
    fi
  fi
else
  new_config="[WebService]
$origins_line"
fi

if write_file_if_changed "$config_file" "$new_config"; then
  log_info "Origins 配置已更新。"
  if service_ensure "cockpit" "restarted"; then
    log_success "外网访问已启用"
  else
    log_warning "Cockpit 服务重启失败，请手动重启。"
  fi
else
  log_info "配置未变更，跳过重启。"
fi

log_success "https://$domain"


}

main "$@"
