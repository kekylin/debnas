#!/bin/bash
# hosts-sync: 定时更新逻辑模块
set -euo pipefail
IFS=$'\n\t'
create_cron_job() {
  if ! update_hosts; then
    log_error "取消创建定时任务。"
    return 1
  fi

  # 使用统一 cron 框架注册定时任务
  if cron_register "hosts-sync" "0 0,6,12,18 * * *"; then
    log_success "定时 0,6,12,18"
  else
    log_error "定时任务注册失败。"
    return 1
  fi
  return 0
}

remove_cron_job() {
  if cron_unregister "hosts-sync"; then
    log_success "定时已取消"
  else
    log_info "未找到定时任务。"
  fi
}

list_cron_jobs() {
  log_info "定时任务如下："
  if cron_is_registered "hosts-sync"; then
    cron_list | grep "hosts-sync" || log_info "已注册（使用 debnas cron list 查看）"
  else
    log_info "当前没有 hosts 更新定时任务。"
  fi
}

