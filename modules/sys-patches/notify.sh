#!/bin/bash
# sys-patches: 邮件通知逻辑
set -euo pipefail
IFS=$'\n\t'
get_hostname() {
  local hostname=$(hostname 2>/dev/null)
  if [[ -z "$hostname" || "$hostname" == "(none)" ]]; then
    get_system_name
  else
    echo "$hostname"
  fi
}

# 验证并获取邮箱配置
# 返回：0 + stdout 输出邮箱地址，1 表示未配置
get_email_config() {
  if [[ ! -f "$EMAIL_CONFIG_FILE" ]] || [[ ! -s "$EMAIL_CONFIG_FILE" ]]; then
    return 1
  fi
  cat "$EMAIL_CONFIG_FILE"
}

# 发送邮件通知
# 注：format_inst_lines()、build_report_content()、run_update_check() 由 check.sh 提供
# shellcheck disable=SC2154  # 以下变量由 check.sh 的 run_update_check() 通过 declare -g 赋值
send_email_notification() {
  local notify_email
  notify_email=$(get_email_config) || {
    log_warning "邮件未配置"
    return 0
  }
  local hostname=$(get_hostname)
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

# 执行更新检测并处理结果
