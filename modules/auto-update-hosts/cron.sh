#!/bin/bash
# auto-update-hosts: 定时更新逻辑模块
set -euo pipefail
IFS=$'\n\t'
create_cron_job() {
  if ! update_hosts; then
    log_fail "取消创建定时任务。"
    return 1
  fi

  # 使用统一 cron 框架注册定时任务
  if cron_register "auto-update-hosts" "0 0,6,12,18 * * *" 2>/dev/null; then
    log_success "定时任务已创建，每天0点、6点、12点和18点自动执行。"
    log_success "hosts 自动更新相关配置已全部完成。"
  else
    log_fail "定时任务注册失败。"
    return 1
  fi
  return 0
}

remove_cron_job() {
  if cron_unregister "auto-update-hosts" 2>/dev/null; then
    log_success "定时任务已删除。"
  else
    log_info "未找到定时任务。"
  fi
}

list_cron_jobs() {
  log_info "定时任务如下："
  if cron_is_registered "auto-update-hosts" 2>/dev/null; then
    cron_list 2>/dev/null | grep "auto-update-hosts" || log_info "已注册（使用 debnas cron list 查看）"
  else
    log_info "当前没有 hosts 更新定时任务。"
  fi
}

