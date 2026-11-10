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

_timer_list_all() {
  echo "定时任务概览"
  echo "────────────────────────────────────────────"
  printf "  %-20s %-8s %s\n" "模块" "状态" "调度"
  echo "────────────────────────────────────────────"
  local module_name display status schedule
  for module_name in "${TIMER_MODULES[@]}"; do
    get_module_field_var display "$module_name" "name" "$module_name" || true
    # cron_is_registered 对变体条目（如 ops-report 年报 "run ops-report 365"）也返回真，
    # 而 cron_get_schedule 只认主条目：只剩变体时取不到调度，不能让 set -e 中止整个概览
    if cron_is_registered "$module_name"; then
      if schedule=$(cron_get_schedule "$module_name"); then
        printf "  %-20s %-8s %s（%s）\n" "$display" "已启用" "$schedule" "$(cron_describe "$schedule")"
      else
        printf "  %-20s %-8s %s\n" "$display" "未启用" "-（仅有附加周期条目）"
      fi
    else
      printf "  %-20s %-8s %s\n" "$display" "未启用" "-"
    fi
  done
  echo "────────────────────────────────────────────"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
# 说明：DebNAS 定时任务都在 root crontab，非 root 无法读取时返回 unknown
module_status() {
  if [[ "${EUID:-1}" -ne 0 ]]; then
    echo "unknown|需 root 读取 root crontab"
    return 0
  fi
  if ! command -v crontab >/dev/null 2>&1; then
    echo "absent|未安装 cron（crontab 命令不存在）"
    return 0
  fi
  local entries=0 enabled=0 module_name
  entries=$(crontab -l 2>/dev/null | grep -cF "$CRON_MARKER" || true)
  entries="${entries:-0}"
  for module_name in "${TIMER_MODULES[@]}"; do
    [[ "$(cron_state "$module_name")" == "on" ]] && enabled=$((enabled + 1))
  done
  if [[ "$entries" -eq 0 ]]; then
    echo "absent|未启用任何 DebNAS 定时任务"
  else
    echo "applied|${entries} 条 DEBNAS-CRON 条目 · ${#TIMER_MODULES[@]} 个可定时模块中 ${enabled} 个已启用"
  fi
}

# 预演：每行 "类型|目标|备注"（无副作用）
module_plan() {
  local IFS=$' \n\t'
  echo "info|定时任务概览|只读列出 ${TIMER_MODULES[*]} 的定时状态与调度，不修改 crontab"
  return 0
}

main() {
  _timer_list_all
  module_mark_action
  return 0
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
