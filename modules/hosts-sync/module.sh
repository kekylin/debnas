#!/bin/bash
# @module: hosts-sync
# @name: Hosts 优化
# @category: 系统工具
# @depends: dig,ping
# @interactive: true
# @version: 2.0.0
# @order: 73
# @cron: true
# @cron_schedule: 0 0 * * *
# 功能：自动更新 /etc/hosts 文件（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# CRON_MODE 兼容
CRON_MODE="${DEBNAS_CRON_MODE:-0}"
if [[ "${1:-}" == "auto_update_hosts" ]]; then
  CRON_MODE=1
fi

# 加载子模块
# DNS 服务器配置（固定顺序，必须在子模块加载前定义）
readonly -a DNS_NAME_ORDER=("AliDNS" "TencentDNS" "BaiduDNS" "DNS114")

# 全局常量（供子模块使用）
readonly HOSTS_FILE="/etc/hosts"
readonly START_MARK="# DebNAS Hosts Start"
readonly END_MARK="# DebNAS Hosts End"

source "${MODULE_DIR}/dns-resolve.sh"
source "${MODULE_DIR}/connectivity.sh"
source "${MODULE_DIR}/hosts-manager.sh"

# 导出函数供并行子 shell 使用（所有子模块加载完毕后统一导出）
export -f resolve_domain get_ip_type test_https_connectivity test_tcp_connectivity test_ping_connectivity test_ip_connectivity 2>/dev/null || true

declare -Ar DNS_IP_BY_NAME=(
  ["AliDNS"]="223.5.5.5"
  ["TencentDNS"]="119.29.29.29"
  ["BaiduDNS"]="180.76.76.76"
  ["DNS114"]="114.114.114.114"
)

declare -A DNS_NAMES=()
DNS_SERVERS=()
for dns_name in "${DNS_NAME_ORDER[@]}"; do
  ip="${DNS_IP_BY_NAME[$dns_name]}"
  DNS_SERVERS+=("$ip")
  DNS_NAMES["$ip"]="$dns_name"
done


setup_temp_environment() {
  # 复用 lib/system/tempfile.sh 的 init_temp_dir，创建并初始化 /tmp/debnas
  init_temp_dir || return 1
  export TMP_DIR="${DEBNAS_TMP_BASE}"
}

# 生成域名哈希值用于临时文件名
# 参数：$1 - 域名
# 返回：MD5 哈希值（32 字符）

module_enable_feature() {
  ensure_module_deps hosts-sync || return 1
  setup_temp_environment
  init_domains_config
  install_missing_dependencies dig ping curl || true
  log_info "更新 Hosts..."
  update_hosts
  feature_enable "hosts-sync"
  log_success "Hosts 同步已启用"
  return 0
}

module_disable_feature() {
  feature_disable "hosts-sync"
  cron_unregister "hosts-sync" || true
  log_success "Hosts 同步已禁用"
  return 0
}

menu() {
  local -a items=("启用 Hosts 同步" "禁用 Hosts 同步" "定时设置")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "Hosts 优化" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   continue ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"
    case "$choice" in
      0) module_enable_feature ;;
      1) module_disable_feature ;;
      2) cron_settings_menu "hosts-sync" ;;
    esac
  done
}

main() {
  if [[ "${1:-}" == "enable" ]]; then
    module_enable_feature
    return $?
  fi
  if [[ "${1:-}" == "disable" ]]; then
    module_disable_feature
    return $?
  fi

  if [[ $CRON_MODE -eq 0 ]]; then
    if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
      # --yes 模式：跳过菜单，直接执行单次更新
      setup_temp_environment
      init_domains_config
      install_missing_dependencies dig ping curl || true
      update_hosts
    else
      menu
    fi
  else
    setup_temp_environment
    init_domains_config
    install_missing_dependencies dig ping curl || true
    update_hosts
    exit 0
  fi
}

main "$@"
