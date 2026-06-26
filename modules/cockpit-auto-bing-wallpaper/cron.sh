#!/bin/bash
# cockpit-auto-bing-wallpaper: 定时更新模块
set -euo pipefail
IFS=$'\n\t'
add_cron_job() {
  local cron_expr="$1"

  if cron_register "cockpit-auto-bing-wallpaper" "$cron_expr" 2>/dev/null; then
    log_to_file log_success "定时任务已添加：$cron_expr"
  else
    log_to_file log_error "定时任务注册失败"
    return 1
  fi
}


show_cron_jobs() {
  log_info "当前定时任务："
  if cron_is_registered "cockpit-auto-bing-wallpaper" 2>/dev/null; then
    cron_list 2>/dev/null | grep "cockpit-auto-bing-wallpaper" || log_info "已注册（使用 debnas cron list 查看）"
  else
    echo "(无定时任务)"
  fi
}

# 功能启用

auto_update_mode() {
  if update_wallpaper; then
    generate_css
    restart_cockpit
  fi
}

# 交互式菜单
