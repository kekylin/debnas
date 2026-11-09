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
# 通知邮件经 /usr/sbin/exim4 发送；收件邮箱见 lib/system/layout.sh 的 notify_email_get
REQUIRED_CMDS=(apt grep awk exim4 systemctl)

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
    choice=$(<"$menu_result")
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

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 上次执行结果（module-runner 写入的 state：last_result / last_run）
# 输出："成功 2026-11-08 00:00" / "失败 …" / 空
_sp_last_run_desc() {
  local result run label
  result=$(state_get "sys-patches" "last_result" 2>/dev/null) || result=""
  run=$(state_get "sys-patches" "last_run" 2>/dev/null) || run=""
  [[ -n "$result" ]] || return 0
  case "$result" in
    success) label="成功" ;;
    fail)    label="失败" ;;
    *)       label="$result" ;;
  esac
  run="${run/T/ }"
  printf '上次执行%s %s' "$label" "${run:0:16}"
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  local cron enabled=0 last schedule="" sched_desc=""
  cron=$(cron_state "sys-patches")
  feature_enabled "sys-patches" 2>/dev/null && enabled=1
  last=$(_sp_last_run_desc)
  if [[ "$cron" == "on" ]]; then
    schedule=$(cron_get_schedule "sys-patches" 2>/dev/null) || schedule=""
    [[ -n "$schedule" ]] && sched_desc="（$(cron_describe "$schedule")）"
  fi

  if [[ "$cron" == "on" ]]; then
    if [[ "$last" == 上次执行失败* ]]; then
      echo "warn|定时检查已启用${sched_desc} · ${last}"
    else
      echo "running|定时检查已启用${sched_desc}${last:+ · ${last}}"
    fi
  elif [[ "$cron" == "off" ]]; then
    if [[ "$enabled" -eq 1 ]]; then
      echo "partial|已启用，未设定时任务${last:+ · ${last}}"
    else
      echo "absent|未启用${last:+ · ${last}}"
    fi
  else
    if [[ "$enabled" -eq 1 ]]; then
      echo "applied|已启用（定时任务需 root 查看）${last:+ · ${last}}"
    else
      echo "absent|未启用（定时任务需 root 查看）${last:+ · ${last}}"
    fi
  fi
}

# 预演：每行 "类型|目标|备注"（无副作用；交互式模块，列出菜单动作的影响范围）
module_plan() {
  local IFS=$' \n\t'
  local -a missing=()
  local cmd cron
  cron=$(cron_state "sys-patches")

  echo "info|动作范围|交互菜单：启用/禁用更新检查、定时设置；--yes 直接检测一次；cron 模式检测后有更新才发邮件"
  for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] \
    && echo "risk|${missing[*]}|缺少依赖命令：启用/检测会直接报错退出（exim4 由「配置邮件账户」前置安装，模块不自动安装）"
  echo "info|apt update|检测时刷新软件包索引（联网，跨进程去重）并模拟 apt-get upgrade -s，不安装任何更新"
  echo "info|邮件|发现更新时经 exim4 发送到通知邮箱（未配置则跳过）"
  echo "write|${DEBNAS_FEATURE_DIR:-/var/lib/debnas/state}/sys-patches.enabled|启用/禁用：记录功能开关（DebNAS 自有目录）"
  case "$cron" in
    on)
      local schedule=""
      schedule=$(cron_get_schedule "sys-patches" 2>/dev/null) || schedule=""
      echo "info|定时任务|已启用：${schedule}（$(cron_describe "$schedule")）"
      ;;
    *) echo "cron|sys-patches|定时设置：默认每天 00:00（可自定义 cron 表达式），未启用功能时自动启用" ;;
  esac
  echo "cron|sys-patches|禁用：移除 sys-patches 定时条目"
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
    # shellcheck disable=SC2154  # 两个计数由 check.sh 的 run_update_check 以 declare -g 赋值
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
