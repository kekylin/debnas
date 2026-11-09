#!/bin/bash
# @module: hosts-sync
# @name: 同步 Hosts
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
export -f resolve_domain get_ip_type is_usable_public_ip test_https_connectivity test_tcp_connectivity test_ping_connectivity test_ip_connectivity 2>/dev/null || true

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
  # 复用 lib/system/tempfile.sh 的 init_temp_dir；放进本进程 PID 子目录（700，退出时随目录清理）
  init_temp_dir || return 1
  export TMP_DIR="${_DEBNAS_PID_DIR}"
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
  if ! update_hosts; then
    log_warning "本次未能更新 Hosts（原 hosts 保持不变），将在下次定时任务时重试"
  fi
  feature_enable "hosts-sync"
  log_success "Hosts 同步已启用"
  module_mark_action
  return 0
}

module_disable_feature() {
  feature_disable "hosts-sync"
  cron_unregister "hosts-sync" || true
  # 同时清除 /etc/hosts 中的 DebNAS 区块，避免禁用后仍沿用过期 IP
  if remove_hosts_block; then
    log_info "已移除 ${HOSTS_FILE} 中的 DebNAS Hosts 区块"
  else
    log_warning "移除 ${HOSTS_FILE} 中的 DebNAS Hosts 区块失败，请手动检查"
  fi
  log_success "Hosts 同步已禁用"
  module_mark_action
  return 0
}

menu() {
  local -a items=("启用 Hosts 同步" "禁用 Hosts 同步" "定时设置")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "同步 Hosts" "${items[@]}" || {
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
      0) module_enable_feature || true ;;   # 失败只提示，不让 set -e 退出菜单
      1) module_disable_feature || true ;;
      2) cron_settings_menu "hosts-sync" ;;
    esac
  done
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 统计 /etc/hosts 中 DebNAS 区块
# 输出："<状态> <条目数> <更新时间>"，状态 ∈ none|ok|broken（有 START 无 END）
_hosts_sync_block_info() {
  [[ -r "${HOSTS_FILE}" ]] || { echo "unreadable 0 -"; return 0; }
  awk -v start="$START_MARK" -v end="$END_MARK" '
    $0 == start { inb = 1; seen = 1; next }
    inb && $0 == end { inb = 0; closed = 1; next }
    inb && /^# 更新时间:/ { sub(/^# 更新时间:[[:space:]]*/, ""); gsub(/[[:space:]]+/, "_"); ts = $0; next }
    inb && $0 !~ /^[[:space:]]*(#|$)/ { n++ }
    END {
      st = !seen ? "none" : (closed ? "ok" : "broken")
      printf "%s %d %s\n", st, n + 0, (ts == "" ? "-" : ts)
    }
  ' "${HOSTS_FILE}" 2>/dev/null || echo "none 0 -"
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local info st n ts enabled=0
  info=$(_hosts_sync_block_info)
  st="${info%% *}"; info="${info#* }"
  n="${info%% *}"; ts="${info#* }"
  ts="${ts//_/ }"
  feature_enabled "hosts-sync" 2>/dev/null && enabled=1

  case "$st" in
    unreadable) echo "unknown|无法读取 ${HOSTS_FILE}"; return 0 ;;
    broken) echo "warn|${HOSTS_FILE} 中 DebNAS 区块缺少结束标记（不会自动删除，请手动检查）"; return 0 ;;
    none)
      if [[ $enabled -eq 1 ]]; then
        echo "warn|已启用但 ${HOSTS_FILE} 中无 DebNAS 区块（上次更新可能失败）"
      else
        echo "absent|未启用 Hosts 同步"
      fi
      return 0
      ;;
  esac
  local desc="${n} 条${ts:+ · 更新于 ${ts}}"
  [[ "$ts" == "-" ]] && desc="${n} 条"
  if [[ "$n" -eq 0 ]]; then
    echo "warn|DebNAS 区块为空"
  elif [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "applied|已写入 ${desc}（定时任务需 root 查看）"
  elif cron_is_registered "hosts-sync" 2>/dev/null; then
    echo "applied|已写入 ${desc} · 定时更新已开启"
  else
    echo "partial|已写入 ${desc} · 未设置定时更新（IP 可能过期）"
  fi
}

# 预演：每行 "类型|目标|备注"（交互式模块：列出各菜单动作可能的影响）
module_plan() {
  local IFS=$' \n\t'
  local -a missing=()
  local cmd domain_count=0
  for cmd in dig ping curl; do
    command -v "$cmd" &>/dev/null || missing+=("${cmd_to_pkg[$cmd]:-$cmd}")
  done
  domain_count=$(load_domains 2>/dev/null | grep -c . || true)

  echo "info|hosts-sync|交互式菜单：启用（立即解析并写入）/ 禁用（移除区块）/ 定时设置，按选择执行；--yes 时直接更新一次"
  [[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|启用/更新时自动安装"
  if [[ -f "${DOMAINS_CONF_FILE}" ]]; then
    echo "info|${DOMAINS_CONF_FILE}|域名列表已存在（${domain_count:-0} 个），保留不改"
  else
    echo "write|${DOMAINS_CONF_FILE}|首次创建默认域名列表（${domain_count:-0} 个，新文件）"
  fi
  echo "info|DNS 解析|联网经 AliDNS/TencentDNS/BaiduDNS/DNS114 解析 ${domain_count:-0} 个域名并测试连通性，执行时探测"
  echo "write|${HOSTS_FILE}|启用/更新：重写 DebNAS 区块（区块外内容保留；原地覆盖保留 inode，不另做备份）；禁用：移除区块"
  if [[ ${EUID:-$(id -u)} -eq 0 ]] && cron_is_registered "hosts-sync" 2>/dev/null; then
    echo "info|cron|定时更新已开启（$(cron_get_schedule hosts-sync 2>/dev/null || echo 已注册)）；禁用时移除"
  else
    echo "cron|hosts-sync|仅当在「定时设置」中启用时写入 root crontab（默认 0 0 * * *）；禁用时移除"
  fi
  echo "risk|域名解析|列表内域名将固定解析到写入的 IP，未开定时更新时 IP 过期可能导致访问失败"
  return 0
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
