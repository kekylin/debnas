#!/bin/bash
# 登录通知 — 禁用逻辑

disable_login_mail() {
  NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
  PAM_FILE="/etc/pam.d/common-session"

  if grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
    sed -i "/session optional pam_exec.so debug \/bin\/bash \/etc\/pam.d\/login-notify.sh/d" "$PAM_FILE"
    log_success "登录通知已移除"
  else
    log_info "登录通知未配置"
  fi

  if [ -f "$NOTIFY_SCRIPT" ]; then
    rm -f "$NOTIFY_SCRIPT"
    log_info "已删除登录通知脚本 $NOTIFY_SCRIPT。"
  fi
}
