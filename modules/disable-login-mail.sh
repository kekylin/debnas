#!/bin/bash
# 功能：禁用用户登录邮件通知（移除pam脚本配置）
# 参数：无（可根据需要扩展）
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
PAM_FILE="/etc/pam.d/common-session"

# 检查 pam.d/common-session 配置
if grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
  sed -i "\|session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT|d" "$PAM_FILE"
  log_success "已从 pam.d/common-session 移除登录通知配置"
else
  log_info "pam.d/common-session 中未找到登录通知配置"
fi

# 删除通知脚本
if [ -f "$NOTIFY_SCRIPT" ]; then
  rm -f "$NOTIFY_SCRIPT"
  log_info "已删除登录通知脚本 $NOTIFY_SCRIPT"
fi

# 可选优化建议：
# 1. 检查并清理相关定时任务或其他通知方式 
