#!/bin/bash
# BBR 拥塞控制算法管理工具

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

readonly BBR_MODULE="tcp_bbr"
readonly BBR_ALGO="bbr"
readonly DEFAULT_ALGO="cubic"
readonly SYSCONF_FILE="/etc/sysctl.conf"
readonly SYSCONF_KEY="net.ipv4.tcp_congestion_control"

validate_numeric_input() {
  local input="$1"
  [[ "$input" =~ ^[0-9]+$ ]]
}

check_current_algo() {
  local current_algo supported_algos
  current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  supported_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
  log_info "当前拥塞控制算法：$current_algo"
  log_info "系统支持算法：$supported_algos"
}

load_bbr_module() {
  # 检查内核模块文件
  local kernel_module="/lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr.ko"
  if [[ ! -f "$kernel_module" ]]; then
    log_fail "内核不支持 BBR 模块，请升级内核或重新编译。"
    return 1
  fi
  
  # 检查模块是否已加载
  if lsmod | grep -q "$BBR_MODULE"; then
    log_success "BBR 模块已加载"
    return 0
  fi
  
  # 尝试加载模块
  log_action "正在加载 BBR 模块..."
  if modprobe "$BBR_MODULE" 2>/dev/null; then
    log_success "BBR 模块加载成功"
    return 0
  else
    log_fail "BBR 模块加载失败，请检查内核配置。"
    return 1
  fi
}

temp_enable_bbr() {
  log_action "正在临时启用 BBR 算法..."
  if ! load_bbr_module; then return 1; fi
  if sysctl -w net.ipv4.tcp_congestion_control="$BBR_ALGO" >/dev/null 2>&1; then
    log_success "BBR 算法临时启用成功"
  else
    log_fail "BBR 算法启用失败，请检查系统权限。"
    return 1
  fi
}

perm_enable_bbr() {
  log_action "正在永久启用 BBR 算法..."
  if ! load_bbr_module; then return 1; fi
  if ! sysctl -w net.ipv4.tcp_congestion_control="$BBR_ALGO" >/dev/null 2>&1; then
    log_fail "BBR 算法启用失败，请检查系统权限。"
    return 1
  fi
  sed -i "/^${SYSCONF_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  echo "$SYSCONF_KEY = $BBR_ALGO" >> "$SYSCONF_FILE"
  if sysctl -p >/dev/null 2>&1; then
    log_success "BBR 算法永久启用成功"
  else
    log_warning "配置应用失败，但 BBR 已临时启用"
  fi
}

temp_disable_bbr() {
  log_action "正在临时关闭 BBR 算法..."
  if sysctl -w net.ipv4.tcp_congestion_control="$DEFAULT_ALGO" >/dev/null 2>&1; then
    log_success "已切换回 $DEFAULT_ALGO 算法"
  else
    log_fail "算法切换失败，请检查系统权限。"
    return 1
  fi
}

perm_disable_bbr() {
  log_action "正在永久关闭 BBR 算法..."
  if ! sysctl -w net.ipv4.tcp_congestion_control="$DEFAULT_ALGO" >/dev/null 2>&1; then
    log_fail "算法切换失败，请检查系统权限。"
    return 1
  fi
  sed -i "/^${SYSCONF_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  if sysctl -p >/dev/null 2>&1; then
    log_success "BBR 算法永久关闭成功"
  else
    log_warning "配置应用失败，但算法已临时切换"
  fi
}

show_menu() {
  print_separator "-"
  print_menu_item "1" "启用 BBR（临时）"
  print_menu_item "2" "启用 BBR（永久）"
  print_menu_item "3" "关闭 BBR（临时）"
  print_menu_item "4" "关闭 BBR（永久）"
  print_menu_item "5" "BBR 状态"
  print_menu_item "0" "退出"
  print_separator "-"
}

handle_choice() {
  local choice="$1"
  case "$choice" in
    1) temp_enable_bbr ;;
    2) perm_enable_bbr ;;
    3) temp_disable_bbr ;;
    4) perm_disable_bbr ;;
    5) check_current_algo ;;
    0) log_action "退出 BBR 管理"; exit 0 ;;
    *) log_fail "无效编号，请重新选择。"; return 1 ;;
  esac
}

main() {
  if ! is_root_user; then
    log_fail "此脚本需要 root 权限运行。"
    exit "${ERROR_PERMISSION}"
  fi
  if ! verify_system_support; then
    log_fail "当前系统不支持此功能。"
    exit "${ERROR_UNSUPPORTED_OS}"
  fi
  while true; do
    show_menu
    print_prompt "请选择编号："
    read -r choice
    if [[ -z "$choice" ]]; then
      log_fail "输入为空，请重新选择。"
      continue
    fi
    if ! validate_numeric_input "$choice"; then
      log_fail "请输入有效编号。"
      continue
    fi
    handle_choice "$choice"
    echo
  done
}

main "$@"