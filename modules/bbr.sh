#!/bin/bash
# @module: bbr
# @name: BBR 加速
# @category: 系统工具
# @depends:
# @version: 1.0.0
# @order: 76
# @interactive: true
# BBR 拥塞控制算法管理工具

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

readonly BBR_MODULE="tcp_bbr"
readonly BBR_ALGO="bbr"
readonly DEFAULT_ALGO="cubic"
readonly SYSCONF_FILE="/etc/sysctl.d/11-debnas-bbr.conf"
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

validate_numeric_input() {
  local input="$1"
  [[ "$input" =~ ^[0-9]+$ ]]
}

check_current_algo() {
  local current_algo supported_algos current_qdisc
  current_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  supported_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  log_info "当前: $current_algo"
  log_info "可用: $supported_algos"
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
      log_success "BBR 模块"
      return 0
    fi
  fi

  log_error "BBR 模块不可用"
  return 1
}

temp_enable_bbr() {
  log_info "临时启用 BBR..."
  if ! load_bbr_module; then return 1; fi
  if sysctl -w net.ipv4.tcp_congestion_control="$BBR_ALGO" >/dev/null 2>&1 && \
     sysctl -w net.core.default_qdisc="$QDISC_FQ" >/dev/null 2>&1; then
    log_success "BBR (临时)"
  else
    log_error "BBR 失败"
    return 1
  fi
}

perm_enable_bbr() {
  log_info "永久启用 BBR..."
  if ! load_bbr_module; then return 1; fi
  if ! sysctl -w net.ipv4.tcp_congestion_control="$BBR_ALGO" >/dev/null 2>&1; then
    log_error "BBR 失败"
    return 1
  fi
  # 同步设置队列规则为 fq
  sysctl -w net.core.default_qdisc="$QDISC_FQ" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免重复配置
  comment_out_sysctl_conf_key "$SYSCONF_KEY"
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY"
  # 持久化到 /etc/sysctl.d/
  sysctl_persist "$SYSCONF_KEY" "$BBR_ALGO" "${SYSCONF_FILE##*/}"
  sysctl_persist "$SYSCONF_QDISC_KEY" "$QDISC_FQ" "${SYSCONF_FILE##*/}"
  if service_ensure systemd-sysctl restarted; then
    log_success "BBR (永久)"
  else
    log_warning "配置已写入 $SYSCONF_FILE，但应用失败；已临时启用 BBR"
  fi
}

temp_disable_bbr() {
  log_info "临时关闭 BBR..."
  if sysctl -w net.ipv4.tcp_congestion_control="$DEFAULT_ALGO" >/dev/null 2>&1 && \
     sysctl -w net.core.default_qdisc="$DEFAULT_QDISC" >/dev/null 2>&1; then
    log_success "${DEFAULT_ALGO} 已启用"
  else
    log_error "算法切换失败，请检查系统权限。"
    return 1
  fi
}

perm_disable_bbr() {
  log_info "永久关闭 BBR..."
  if ! sysctl -w net.ipv4.tcp_congestion_control="$DEFAULT_ALGO" >/dev/null 2>&1; then
    log_error "算法切换失败，请检查系统权限。"
    return 1
  fi
  # 恢复默认队列规则
  sysctl -w net.core.default_qdisc="$DEFAULT_QDISC" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免旧方式残留导致关闭不彻底
  comment_out_sysctl_conf_key "$SYSCONF_KEY"
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY"
  # 移除 BBR 专用配置文件
  if [[ -f "$SYSCONF_FILE" ]]; then
    rm -f "$SYSCONF_FILE"
    log_info "已移除 ${SYSCONF_FILE}"
  fi
  if service_ensure systemd-sysctl restarted; then
    log_success "BBR 已关闭"
  else
    log_warning "配置已从 $SYSCONF_FILE 移除，但应用失败；算法已临时切换"
  fi
}

handle_choice() {
  local choice="$1"
  case "$choice" in
    1) temp_enable_bbr ;;
    2) perm_enable_bbr ;;
    3) temp_disable_bbr ;;
    4) perm_disable_bbr ;;
    5) check_current_algo ;;
    0) log_info "退出 BBR 管理"; return 0 ;;
    *) log_error "无效编号，请重新选择。"; return 1 ;;
  esac
}

main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi

  # 非交互模式：通过参数指定操作（1=启用临时 2=启用永久 3=禁用临时 4=禁用永久 5=状态）
  if [[ ! -t 0 ]] || [[ -n "${1:-}" ]]; then
    local choice="${1:-5}"
    handle_choice "$choice"
    return $?
  fi

  local -a items=("启用 BBR（临时）" "启用 BBR（永久）" "关闭 BBR（临时）" "关闭 BBR（永久）" "BBR 状态")
  local choice exit_code
  while true; do
    choice=$(ui_menu "BBR 拥塞控制" "${items[@]}") || {
      exit_code=$?
      case $exit_code in
        254) return 0 ;;   # Esc：退出模块
        255) return 0 ;;   # Q：退出模块
        *)   return 0 ;;
      esac
    }
    # ui_menu 返回 0-based 索引，handle_choice 使用 1-based
    handle_choice "$((choice + 1))"
    echo
  done
}

main "$@"