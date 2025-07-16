#!/bin/bash
# 功能：启用用户登录邮件通知（配置pam脚本，登录时自动发邮件）
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

# 检查依赖
REQUIRED_CMDS=(exim4)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先配置邮件账户并安装 exim4"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查邮件配置文件
EMAIL_FILE="/etc/exim4/notify_email"
if [[ ! -f "$EMAIL_FILE" ]]; then
  log_error "未找到邮件配置文件 $EMAIL_FILE，请先运行"设置发送邮件账户"模块"
  exit "${ERROR_DEPENDENCY}"
fi

# 读取通知邮箱地址
read -r notify_email < "$EMAIL_FILE" || {
  log_error "无法读取通知邮箱地址，请检查文件 $EMAIL_FILE"
  exit "${ERROR_GENERAL}"
}

if [[ -z "$notify_email" ]]; then
  log_error "通知邮箱地址为空，请先运行"设置发送邮件账户"模块"
  exit "${ERROR_DEPENDENCY}"
fi

log_info "接收通知邮箱: $notify_email"

# 配置 pam.d/common-session 登录通知
NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
cat > "$NOTIFY_SCRIPT" << EOF
#!/bin/bash
export LANG="en_US.UTF-8"
[ "\$PAM_TYPE" = "open_session" ] || exit 0
{
    echo "To: $notify_email"
    echo "Subject: 注意！\$PAM_USER通过\$PAM_SERVICE登录\$(hostname -s)"
    echo
    echo "登录事件详情:"
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

# 添加到 pam.d/common-session
PAM_FILE="/etc/pam.d/common-session"
if ! grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
  echo "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" >> "$PAM_FILE"
  log_success "已添加登录邮件通知配置到 pam.d/common-session"
else
  log_info "pam.d/common-session 中已存在登录通知配置"
fi

# 可选优化建议：
# 1. 支持自定义收件人和邮件内容模板
# 2. 支持多种登录方式（如 su、root 权限操作）通知 
