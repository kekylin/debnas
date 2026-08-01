#!/bin/bash
# @module: sys-patches
# @name: 检查系统更新
# @category: 系统维护
# @depends:
# @version: 1.0.0
# @order: 71
# @cron: true
# @cron_schedule: 0 0 * * *
# @interactive: true
# 功能：系统更新检查与邮件通知（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 加载子模块 ====================
source "${MODULE_DIR}/check.sh"
source "${MODULE_DIR}/notify.sh"

# ==================== 常量定义 ====================
REQUIRED_CMDS=(apt grep awk mail systemctl)
EMAIL_CONFIG_FILE="/etc/exim4/notify_email"

# ==================== 菜单函数（交互模式） ====================

main_menu() {
  if ! verify_system_support; then
    return 1
  fi

  local -a items=("启用更新检查" "禁用更新检查" "定时设置")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "检查系统更新" "${items[@]}" || {
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
      2) cron_settings_menu "sys-patches" ;;
    esac
  done
}

# ==================== 功能开关 ====================

module_enable_feature() {
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
    return 1
  fi
  if ! verify_system_support; then
    return 1
  fi
  execute_update_check
  feature_enable "sys-patches"
  log_success "系统更新已启用"
  module_mark_action
  return 0
}

module_disable_feature() {
  feature_disable "sys-patches"
  cron_unregister "sys-patches" || true
  log_success "系统更新已禁用"
  module_mark_action
  return 0
}

# ==================== 主入口 ====================

main() {
  if [[ "${1:-}" == "enable" ]]; then
    module_enable_feature
    return $?
  fi
  if [[ "${1:-}" == "disable" ]]; then
    module_disable_feature
    return $?
  fi

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
      log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
      exit "${ERROR_DEPENDENCY}"
    fi
    # 定时任务模式：执行检测，有更新时发送邮件通知
    if ! verify_system_support; then
      exit "${ERROR_UNSUPPORTED_OS}"
    fi
    run_update_check
    if [[ $security_update_count -gt 0 || $regular_update_count -gt 0 ]]; then
      send_email_notification
    fi
  elif [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
    if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
      log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
      exit "${ERROR_DEPENDENCY}"
    fi
    # --yes 模式：跳过菜单，直接执行检测
    if ! verify_system_support; then
      exit "${ERROR_UNSUPPORTED_OS}"
    fi
    execute_update_check
  else
    # 交互模式：显示菜单
    main_menu
  fi
}

main "$@"
