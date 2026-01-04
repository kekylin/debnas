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
readonly SYSCONF_DIR="/etc/sysctl.d"
readonly SYSCONF_FILE="/etc/sysctl.d/99-debnas.conf"
readonly SYSCONF_KEY="net.ipv4.tcp_congestion_control"
readonly SYSCONF_QDISC_KEY="net.core.default_qdisc"
readonly QDISC_FQ="fq"
readonly DEFAULT_QDISC="fq_codel"

comment_out_sysctl_conf_key() {
  local key="$1"
  local conf="/etc/sysctl.conf"
  [ -f "$conf" ] || return 0

  # 使用固定正则，严格匹配“带等号”的完整配置行
  local key_regex='^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*.*$'
  local commented_regex='^[[:space:]]*#[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*='

  # 已注释则跳过
  if LC_ALL=C grep -nE "$commented_regex" "$conf" >/dev/null 2>&1; then
    return 0
  fi

  # 未注释的同名键则注释
  if LC_ALL=C grep -nE "$key_regex" "$conf" >/dev/null 2>&1; then
    sed -i -E 's|^([[:space:]]*)net\.ipv4\.tcp_congestion_control([[:space:]]*=[[:space:]]*.*)?$|\1# net.ipv4.tcp_congestion_control\2|' "$conf" 2>/dev/null || true
    if LC_ALL=C grep -nE "$commented_regex" "$conf" >/dev/null 2>&1; then
      log_success "已注释 ${conf} 中的重复配置项：${key}"
      return 0
    else
      log_warning "尝试注释 ${conf} 中的 ${key} 失败"
      return 1
    fi
  fi
  return 0
}
ensure_sysctl_file() {
  if [ ! -d "$SYSCONF_DIR" ]; then
    mkdir -p "$SYSCONF_DIR"
  fi
  if [ ! -f "$SYSCONF_FILE" ]; then
    touch "$SYSCONF_FILE"
    chmod 644 "$SYSCONF_FILE"
  fi
}


validate_numeric_input() {
  local input="$1"
  [[ "$input" =~ ^[0-9]+$ ]]
}

check_current_algo() {
  local current_algo supported_algos current_qdisc
  current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  supported_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  log_info "当前拥塞控制算法：$current_algo"
  log_info "系统支持算法：$supported_algos"
  log_info "当前队列规则：$current_qdisc"
}

load_bbr_module() {
  # 模块已加载
  if lsmod | awk '{print $1}' | grep -qx "$BBR_MODULE"; then
    log_success "BBR 模块已加载"
    return 0
  fi

  # 若可用则加载（兼容 .ko 与 .ko.xz）
  if modinfo "$BBR_MODULE" >/dev/null 2>&1; then
    if modprobe "$BBR_MODULE" >/dev/null 2>&1; then
      log_success "BBR 模块加载成功"
      return 0
    fi
  fi

  log_fail "未找到可用的 BBR 模块（tcp_bbr），请检查内核或模块路径"
  return 1
}

temp_enable_bbr() {
  log_action "正在临时启用 BBR 算法..."
  if ! load_bbr_module; then return 1; fi
  if sysctl -w net.ipv4.tcp_congestion_control="$BBR_ALGO" >/dev/null 2>&1 && \
     sysctl -w net.core.default_qdisc="$QDISC_FQ" >/dev/null 2>&1; then
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
  # 同步设置队列规则为 fq
  sysctl -w net.core.default_qdisc="$QDISC_FQ" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免重复配置
  comment_out_sysctl_conf_key "$SYSCONF_KEY"
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY"
  ensure_sysctl_file
  sed -i "/^${SYSCONF_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  echo "$SYSCONF_KEY = $BBR_ALGO" >> "$SYSCONF_FILE"
  sed -i "/^${SYSCONF_QDISC_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  echo "$SYSCONF_QDISC_KEY = $QDISC_FQ" >> "$SYSCONF_FILE"
  if systemctl restart systemd-sysctl.service >/dev/null 2>&1; then
    log_success "BBR 算法永久启用成功"
  else
    log_warning "配置已写入 $SYSCONF_FILE，但应用失败；已临时启用 BBR"
  fi
}

temp_disable_bbr() {
  log_action "正在临时关闭 BBR 算法..."
  if sysctl -w net.ipv4.tcp_congestion_control="$DEFAULT_ALGO" >/dev/null 2>&1 && \
     sysctl -w net.core.default_qdisc="$DEFAULT_QDISC" >/dev/null 2>&1; then
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
  # 恢复默认队列规则
  sysctl -w net.core.default_qdisc="$DEFAULT_QDISC" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免旧方式残留导致关闭不彻底
  comment_out_sysctl_conf_key "$SYSCONF_KEY"
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY"
  ensure_sysctl_file
  sed -i "/^${SYSCONF_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  sed -i "/^${SYSCONF_QDISC_KEY}[[:space:]]*=/d" "$SYSCONF_FILE" 2>/dev/null || true
  if systemctl restart systemd-sysctl.service >/dev/null 2>&1; then
    log_success "BBR 算法永久关闭成功"
  else
    log_warning "配置已从 $SYSCONF_FILE 移除，但应用失败；算法已临时切换"
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