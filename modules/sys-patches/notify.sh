#!/bin/bash
# sys-patches: 邮件通知逻辑
set -euo pipefail
IFS=$'\n\t'
# 邮件主题按 RFC 2047 编码（UTF-8 Base64）
# 参数：$1 - 主题原文
# 输出：每 10 个字符一个 encoded-word（≤ 40 字节，编码后不超过 75 字符），多段折行续写
_sp_mime_subject() {
  local s="${1-}" out="" i=0 LC_ALL=C.UTF-8
  while (( i < ${#s} )); do
    out+="${out:+$'\n '}=?UTF-8?B?$(printf '%s' "${s:i:10}" | base64 -w0)?="
    i=$((i + 10))
  done
  printf '%s' "$out"
}

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
  # exim4 -oi：正文中单独一行 "." 不会被当作消息结束
  {
    echo "Subject: $(_sp_mime_subject "$subject")"
    echo "To: ${notify_email}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo -e "$report_content"
  } | /usr/sbin/exim4 -oi -t
}
