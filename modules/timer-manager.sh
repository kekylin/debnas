#!/bin/bash
# @module: timer-manager
# @name: 定时任务概览
# @category: 系统维护
# @version: 1.0.0
# @order: 80
# @interactive: true
# @depends:
# 功能：统一管理所有支持定时任务的模块

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

readonly TIMER_MODULES=("sys-patches" "wallpaper" "hosts-sync" "threat-ips" "ops-report")

_timer_display_name() {
  local module_name="$1"
  get_module_field "$module_name" "name" "$module_name" 2>/dev/null || echo "$module_name"
}

_timer_list_all() {
  echo "定时任务概览"
  echo "────────────────────────────────────────────"
  printf "  %-20s %-8s %s\n" "模块" "状态" "调度"
  echo "────────────────────────────────────────────"
  local module_name display status schedule
  for module_name in "${TIMER_MODULES[@]}"; do
    display=$(_timer_display_name "$module_name")
    if cron_is_registered "$module_name"; then
      schedule=$(cron_get_schedule "$module_name")
      printf "  %-20s %-8s %s（%s）\n" "$display" "已启用" "$schedule" "$(cron_describe "$schedule")"
    else
      printf "  %-20s %-8s %s\n" "$display" "未启用" "-"
    fi
  done
  echo "────────────────────────────────────────────"
}

main() {
  _timer_list_all
  module_mark_action
  return 0
}

main "$@"
