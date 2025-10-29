#!/bin/bash
# 功能：禁用用户登录邮件通知（移除 pam 脚本配置）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
PAM_FILE="/etc/pam.d/common-session"

# 移除 pam.d/common-session 中的登录通知配置
if grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
  sed -i "/session optional pam_exec.so debug \/bin\/bash \/etc\/pam.d\/login-notify.sh/d" "$PAM_FILE"
  log_success "已从 pam.d/common-session 移除登录通知配置。"
else
  log_info "pam.d/common-session 中未找到登录通知配置，跳过操作。"
fi

# 删除登录通知脚本，避免遗留安全隐患
if [ -f "$NOTIFY_SCRIPT" ]; then
  rm -f "$NOTIFY_SCRIPT"
  log_info "已删除登录通知脚本 $NOTIFY_SCRIPT。"
fi
