#!/bin/bash
# @module: sys-patches
# @name: 系统更新
# @category: 系统维护
# @depends:
# @version: 1.0.0
# @order: 71
# @cron: true
# @cron_schedule: 0 6 * * *
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
source "${MODULE_DIR}/cron.sh"

# ==================== 常量定义 ====================
REQUIRED_CMDS=(apt grep awk mail systemctl)
EMAIL_CONFIG_FILE="/etc/exim4/notify_email"

# ==================== 菜单函数（交互模式） ====================

main_menu() {
  if ! verify_system_support; then
    return 1
  fi

  local -a items=("立即执行检测" "设置定时检测" "查看定时任务" "移除定时任务")
  while true; do
    local choice
    choice=$(UI_MENU_BACK_LABEL="← 返回上级" ui_menu "系统更新" "${items[@]}") || {
      case $? in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
      esac
      continue
    }
    case "$choice" in
      0) execute_update_check ;;
      1) schedule_menu ;;
      2) list_cron_tasks ;;
      3) remove_cron_task ;;
    esac
  done
}

_schedule_daily() { set_cron_task "daily"; }
_schedule_weekly() { set_cron_task "weekly"; }

schedule_menu() {
  local -a items=("每日检测（00:00）" "每周检测（周一00:00）" "自定义定时检测")
  while true; do
    local choice
    choice=$(UI_MENU_BACK_LABEL="← 返回上级" ui_menu "定时检测" "${items[@]}") || {
      case $? in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
      esac
      continue
    }
    case "$choice" in
      0) _schedule_daily ;;
      1) _schedule_weekly ;;
      2) set_custom_cron_task ;;
    esac
  done
}

# ==================== 主入口 ====================

main() {
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
    exit "${ERROR_DEPENDENCY}"
  fi

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    # 定时任务模式：执行检测，有更新时发送邮件通知
    if ! verify_system_support; then
      exit "${ERROR_UNSUPPORTED_OS}"
    fi
    run_update_check
    if [[ $security_update_count -gt 0 || $regular_update_count -gt 0 ]]; then
      send_email_notification
    fi
  elif [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
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
