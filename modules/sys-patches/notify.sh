#!/bin/bash
# sys-patches: 邮件通知逻辑
set -euo pipefail
IFS=$'\n\t'
# 发送邮件通知
# 注：format_inst_lines()、build_report_content()、run_update_check() 由 check.sh 提供
# shellcheck disable=SC2154  # 以下变量由 check.sh 的 run_update_check() 通过 declare -g 赋值
send_email_notification() {
  local notify_email
  # 收件邮箱由 lib/system/layout.sh 统一读取（/etc/debnas/notify_email，旧位置回退）
  notify_email=$(notify_email_get) || {
    log_warning "邮件未配置"
    return 0
  }
  local total_count=$((security_update_count + regular_update_count))
  local subject="更新通知 — 发现 ${total_count} 个可用更新"

  log_info "通知邮件 → ${notify_email}"
  {
    echo "Subject: ${subject}"
    echo "To: ${notify_email}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo -e "$report_content"
  } | /usr/sbin/exim4 -t
}
