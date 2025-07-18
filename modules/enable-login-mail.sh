#!/bin/bash
# 功能：启用用户登录邮件通知（通过 PAM 脚本，登录时自动发送邮件）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 exim4 依赖，确保邮件发送功能可用
REQUIRED_CMDS=(exim4)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 exim4 依赖，请先配置邮件账户并安装 exim4。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查邮件通知配置文件是否存在
EMAIL_FILE="/etc/exim4/notify_email"
if [[ ! -f "$EMAIL_FILE" ]]; then
  log_error "未检测到 $EMAIL_FILE，请先通过“设置发送邮件账户”模块完成配置。"
  exit "${ERROR_DEPENDENCY}"
fi

# 读取通知邮箱地址，若读取失败则退出
read -r notify_email < "$EMAIL_FILE" || {
  log_error "无法读取通知邮箱地址，请检查 $EMAIL_FILE 权限及内容。"
  exit "${ERROR_GENERAL}"
}

if [[ -z "$notify_email" ]]; then
  log_error "通知邮箱地址为空，请先通过“设置发送邮件账户”模块完成配置。"
  exit "${ERROR_DEPENDENCY}"
fi

log_info "通知邮箱地址：$notify_email"

# 生成 PAM 登录通知脚本，登录时自动发送邮件
NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
cat > "$NOTIFY_SCRIPT" << EOF
#!/bin/bash
export LANG="en_US.UTF-8"
[ " {PAM_TYPE:-}" = "open_session" ] || exit 0
{
    echo "To: $notify_email"
    echo "Subject: 登录提醒：\$PAM_USER 通过 \$PAM_SERVICE 登录 \$(hostname -s)"
    echo
    echo "登录事件详情："
    echo "----------------"
    echo "用户:         \$PAM_USER"
    echo "远程用户:     \$PAM_RUSER"
    echo
    echo "远程主机:     \$PAM_RHOST"
    echo "服务:         \$PAM_SERVICE"
    echo "终端:         \$PAM_TTY"
    echo
    echo "日期:         \$(date '+%Y-%m-%d %H:%M:%S')"
    echo "服务器:       \$(uname -s -n -r)"
} | /usr/sbin/exim4 -t
EOF
chmod +x "$NOTIFY_SCRIPT"

# 配置 pam.d/common-session，集成登录通知脚本
PAM_FILE="/etc/pam.d/common-session"
if ! grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
  echo "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" >> "$PAM_FILE"
  log_success "已成功集成登录邮件通知至 pam.d/common-session。"
else
  log_info "pam.d/common-session 已存在登录邮件通知配置，无需重复添加。"
fi
