#!/bin/bash
# 功能：定时任务交互菜单（UI 层）
# 说明：lib/system/cron.sh 只保留 crontab/状态数据操作；本文件承载
#       ui_input / ui_menu 交互，由 lib/bootstrap.sh 的 UI 段加载
#       （cron 模式不加载 UI，也不应调用本文件函数）。
# 依赖：core/logging.sh、system/cron.sh、system/feature.sh、system/state.sh、
#       ui/menu.sh、ui/dialog.sh

set -euo pipefail
IFS=$'\n\t'

# 获取模块显示名（供 cron 管理函数内部使用）
_cron_display_name() {
  local module_name="$1"
  get_module_field "$module_name" "name" "$module_name" 2>/dev/null || echo "$module_name"
}

# 交互式启用定时任务：先询问时间，再自动补齐功能并注册
# 参数：$1 - 模块名
# 返回：0 成功，1 失败
cron_enable_interactive() {
  local module_name="${1:?cron_enable_interactive: 缺少模块名}"
  local default_cron="0 0 * * *" input schedule

  input=$(ui_input "请输入定时表达式（留空使用默认每天 00:00）" "$default_cron")
  if [[ -z "$input" ]]; then
    schedule="$default_cron"
  elif cron_validate_schedule "$input"; then
    schedule="$input"
  else
    log_warning "无效定时表达式：${input}，使用默认：${default_cron}"
    schedule="$default_cron"
  fi

  if ! feature_enabled "$module_name"; then
    log_warning "$(_cron_display_name "$module_name") 功能未启用，将自动启用"
    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${DEBNAS_ROOT}/bin/module-runner.sh" "$module_name" enable); then
      log_error "自动启用 $(_cron_display_name "$module_name") 失败"
      return 1
    fi
  fi

  if cron_register "$module_name" "$schedule"; then
    log_success "已启用 $(_cron_display_name "$module_name") 定时任务：${schedule}（$(cron_describe "$schedule")）"
    module_mark_action
  else
    log_error "定时任务注册失败"
    return 1
  fi
  return 0
}

# 模块内“定时设置”统一菜单
# 参数：$1 - 模块名
# 返回：0 返回上级，1 失败
cron_settings_menu() {
  local module_name="${1:?cron_settings_menu: 缺少模块名}"
  local display_name
  display_name=$(_cron_display_name "$module_name")
  local -a items=("启用定时任务（默认每天 00:00）" "禁用定时任务")

  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "${display_name} 定时设置" "${items[@]}" || {
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
      0) cron_enable_interactive "$module_name" ;;
      1)
        if cron_unregister "$module_name"; then
          log_success "已禁用 ${display_name} 定时任务"
          module_mark_action
        else
          log_error "定时任务移除失败"
        fi
        ;;
    esac
  done
}
