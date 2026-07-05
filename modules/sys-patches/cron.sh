#!/bin/bash
# sys-patches: 定时检查逻辑
set -euo pipefail
IFS=$'\n\t'

set_cron_task() {
  local schedule="$1" cron
  [[ "$schedule" == "daily" ]] && cron="0 0 * * *" || cron="0 0 * * 1"

  if cron_register "sys-patches" "$cron"; then
    [[ "$schedule" == "daily" ]] && log_success "每日检测已设置" || log_success "每周检测已设置"
  else
    log_error "设置定时任务失败"
    return 1
  fi
}

set_custom_cron_task() {
  local cron
  read -p "请输入 cron 表达式（示例：0 0 * * * 表示每日00:00）： " cron
  # 由 cron_register 内部校验表达式格式
  if cron_register "sys-patches" "$cron"; then
    log_success "${cron}"
  else
    log_error "设置定时任务失败（表达式无效或 cron 服务不可用）"
    return 1
  fi
}

list_cron_tasks() {
  if cron_is_registered "sys-patches"; then
    cron_list | grep "sys-patches" || log_info "已注册（使用 debnas cron list 查看）"
  else
    log_info "无定时任务"
  fi
}

remove_cron_task() {
  cron_unregister "sys-patches" || true
  log_success "定时已取消"
}
