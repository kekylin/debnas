#!/bin/bash
# @module: sys-patches
# @name: 系统更新
# @category: 系统工具
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
main() {
source "${MODULE_DIR}/check.sh"
source "${MODULE_DIR}/notify.sh"
source "${MODULE_DIR}/cron.sh"

REQUIRED_CMDS=(apt grep awk mail systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 定义文件路径常量
EMAIL_CONFIG_FILE="/etc/exim4/notify_email"

# 获取主机名

main_menu() {
  if ! verify_system_support; then
    return 1
  fi
  while true; do
    print_separator "-"
    print_menu_item "1" "立即执行检测"
    print_menu_item "2" "设置定时检测"
    print_menu_item "3" "查看定时任务"
    print_menu_item "4" "移除定时任务"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r choice
    
    # 验证输入
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      log_error "请输入数字编号"
      continue
    fi
    
    if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt 4 ]]; then
      log_error "无效选择，请输入 0-4"
      continue
    fi
    
    case $choice in
      1) execute_update_check ;;
      2) schedule_menu ;;
      3) list_cron_tasks ;;
      4) remove_cron_task ;;
      0) log_action "返回"; return 0 ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

# 显示定时检测子菜单并处理用户选择
schedule_menu() {
  while true; do
    print_separator "-"
    print_menu_item "1" "每日检测（00:00）"
    print_menu_item "2" "每周检测（周一00:00）"
    print_menu_item "3" "自定义定时检测"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r subchoice
    
    # 验证输入
    if [[ ! "$subchoice" =~ ^[0-9]+$ ]]; then
      log_error "请输入数字编号"
      continue
    fi
    
    if [[ "$subchoice" -lt 0 ]] || [[ "$subchoice" -gt 3 ]]; then
      log_error "无效选择，请输入 0-3"
      continue
    fi
    
    case $subchoice in
      1) set_cron_task "daily"; return ;;
      2) set_cron_task "weekly"; return ;;
      3) set_custom_cron_task; return ;;
      0) log_action "返回"; return ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

# 主程序入口
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
