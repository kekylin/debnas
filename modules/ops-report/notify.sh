#!/bin/bash
# ops-report: 可选邮件通知，正文优先 Markdown，失败不阻断报告
set -euo pipefail
IFS=$'\n\t'

ops_get_notify_email() {
  if [[ ! -f "$OPS_EMAIL_CONFIG" ]] || [[ ! -s "$OPS_EMAIL_CONFIG" ]]; then
    return 1
  fi
  local email
  email=$(head -1 "$OPS_EMAIL_CONFIG" 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$email" ]] || return 1
  printf '%s' "$email"
}

ops_build_markdown_report() {
  cat <<EOF
# DebNAS 运维报告

- 主机名：$(hostname 2>/dev/null || echo "未知")
- 报告周期：最近 ${OPS_REPORT_DAYS} 天
- 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
- 总体状态：${OPS_STATUS_TEXT}

## 摘要

- 系统可用性：连续运行 ${OPS_UPTIME_DAYS} 天
- CPU 平均：${OPS_CPU_AVG}%，峰值 ${OPS_CPU_MAX}%
- 内存平均：${OPS_MEM_AVG}%，当前 ${OPS_MEM_CURRENT_PERCENT}%
- 网络总流量：接收 $(ops_format_bytes "${OPS_NET_TOTAL_RX_BYTES}")，发送 $(ops_format_bytes "${OPS_NET_TOTAL_TX_BYTES}")
- 登录：成功 ${OPS_LOGIN_SUCCESS_COUNT} 次，失败 ${OPS_LOGIN_FAIL_COUNT} 次
- 系统维护：周期内更新 ${OPS_UPDATE_COUNT} 项，待装 ${OPS_PENDING_UPDATE_COUNT} 项
- 待办事项：${OPS_ACTION_COUNT} 项

## 建议与行动项

$(
  if [[ ${#OPS_ACTION_ITEMS[@]} -eq 0 ]]; then
    echo "- 当前没有需要立即处理的建议事项。"
  else
    for item in "${OPS_ACTION_ITEMS[@]}"; do
      echo "- ${item}"
    done
  fi
)

## 详细报告

本地 HTML 报告：${OPS_LAST_REPORT}

此邮件由 DebNAS 自动生成，请勿直接回复。
EOF
}

ops_send_report_email() {
  local days="${1:-${OPS_DEFAULT_PERIOD}}"
  local notify_email
  notify_email=$(ops_get_notify_email) || {
    log_warning "邮件未配置，跳过邮件发送（终端报告仍已生成）"
    return 0
  }

  local hostname subject
  # 主机名去掉控制字符，防止邮件头注入；中文主题按 RFC 2047 编码
  hostname=$(hostname 2>/dev/null | tr -d '\000-\037\177' || true)
  [[ -n "$hostname" ]] || hostname="DebNAS"
  subject="DebNAS 运维报告：${hostname}（最近 ${days} 天）"
  if command -v base64 >/dev/null 2>&1; then
    subject="=?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
  fi

  local attach="" attach_name=""
  if [[ "${OPS_EMAIL_ATTACH_HTML:-1}" -eq 1 ]] \
    && [[ -n "${OPS_LAST_REPORT:-}" ]] && [[ -f "$OPS_LAST_REPORT" ]]; then
    local attach_size
    attach_size=$(wc -c < "$OPS_LAST_REPORT" | tr -d '[:space:]')
    if [[ "$attach_size" -le "${OPS_EMAIL_MAX_ATTACH_BYTES:-2097152}" ]] \
      && command -v base64 >/dev/null 2>&1; then
      attach="$OPS_LAST_REPORT"
      attach_name=$(basename "$OPS_LAST_REPORT")
    else
      log_warning "HTML 附件缺失或超过大小上限，降级为仅发送正文"
    fi
  fi

  local boundary send_rc
  boundary="----=_DebNAS_$(date +%s)_$$"
  # exim4 -oi：正文中单独一行 "." 不会被当作消息结束而截断邮件
  log_info "发送运维报告邮件 → ${notify_email}"
  if [[ -n "$attach" ]]; then
    {
      echo "Subject: ${subject}"
      echo "To: ${notify_email}"
      echo "MIME-Version: 1.0"
      echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
      echo
      echo "--${boundary}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      ops_build_markdown_report
      echo
      echo "--${boundary}"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Disposition: attachment; filename=\"${attach_name}\""
      echo "Content-Transfer-Encoding: base64"
      echo
      base64 "$attach"
      echo
      echo "--${boundary}--"
    } | timeout 30 /usr/sbin/exim4 -oi -t 2>/dev/null && send_rc=0 || send_rc=1
  else
    {
      echo "Subject: ${subject}"
      echo "To: ${notify_email}"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      ops_build_markdown_report
    } | timeout 30 /usr/sbin/exim4 -oi -t 2>/dev/null && send_rc=0 || send_rc=1
  fi

  if [[ "$send_rc" -eq 0 ]]; then
    log_success "运维报告邮件已发送"
  else
    log_warning "运维报告邮件发送失败，不影响本地报告"
  fi
  return 0
}
