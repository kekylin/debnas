#!/bin/bash
# @module: hosts-sync
# @name: Hosts 优化
# @category: 系统工具
# @depends: dig,ping
# @version: 2.0.0
# @order: 73
# @cron: true
# @cron_schedule: 0 3 * * *
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
source "${MODULE_DIR}/cron.sh"

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
  # 权限 755 允许 _apt 等系统用户遍历访问（兼容并行子 shell 场景）
  chmod 755 "${DEBNAS_TMP_BASE}" 2>/dev/null || true
  export TMP_DIR="${DEBNAS_TMP_BASE}"
}

# 生成域名哈希值用于临时文件名
# 参数：$1 - 域名
# 返回：MD5 哈希值（32 字符）

menu() {
  while true; do
    print_separator "-"
    print_menu_item "1" "单次更新"
    print_menu_item "2" "定时更新"
    print_menu_item "3" "删除定时任务"
    print_menu_item "4" "查询定时任务"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r choice

    case "$choice" in
      1)
        log_info "更新 Hosts..."
        update_hosts
        ;;
      2)
        log_info "创建定时任务..."
        create_cron_job
        ;;
      3)
        log_info "删除定时任务..."
        remove_cron_job
        ;;
      4)
        list_cron_jobs
        ;;
      0)
        return 0
        ;;
      *)
        log_fail "无效选择，请重新输入。"
        ;;
    esac
  done
}

main() {
  if [[ $CRON_MODE -eq 0 ]]; then
    setup_temp_environment
    init_domains_config
    # 检查必要依赖
    local missing=()
    for cmd in dig ping curl; do
      command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      log_warning "缺失依赖: ${missing[*]}，尝试安装..."
      install_missing_dependencies "${missing[@]}" 2>/dev/null || true
    fi
    if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
      # --yes 模式：跳过菜单，直接执行单次更新
      update_hosts
    else
      menu
    fi
  else
    setup_temp_environment
    update_hosts
    exit 0
  fi
}

main "$@"
