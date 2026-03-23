#!/bin/bash
# 功能：安装并配置 fail2ban 自动封锁服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 apt、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 apt 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 安装 Fail2ban 软件包，保障安全防护
install_fail2ban() {
  log_info "正在安装 Fail2ban 软件包..."
  apt install fail2ban -y
  if ! command -v fail2ban-server >/dev/null 2>&1; then
    log_error "未检测到 fail2ban，请先安装后再运行本脚本。"
    exit "${ERROR_DEPENDENCY}"
  fi
}

# 配置通知邮箱地址，便于接收告警
configure_email() {
  local notify_file="/etc/exim4/notify_email"
  local email_file="/etc/email-addresses"
  local default_recipient="root@local-system"
  local default_sender="root@system-hostname"

  if [[ -r "$notify_file" ]]; then
    dest_email=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' < "$notify_file")
  else
    log_warning "未找到 $notify_file，使用默认接收邮箱 $default_recipient。"
    dest_email="$default_recipient"
  fi

  if [[ -r "$email_file" ]]; then
    sender_email=$(sed -n 's/^root:[[:space:]]*\(.*\)/\1/p' < "$email_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$sender_email" ]] && sender_email="$default_sender"
  else
    sender_email="$default_sender"
  fi

  DEST_EMAIL="$dest_email"
  SENDER_EMAIL="$sender_email"

  log_info "接收告警通知邮箱：$dest_email"
  log_info "告警邮件发件人邮箱：$sender_email"
}

# 配置 jail.local，定制 fail2ban 行为
configure_jail_local() {
  local config_file="/etc/fail2ban/jail.local"
  cat > "$config_file" <<EOF
[DEFAULT]

# 忽略本机流量，防止自身被封禁
ignoreip = 127.0.0.1/8 ::1

# 封禁时长（-1 表示永久封禁）
bantime  = 1h

# 统计失败尝试的时间窗口
findtime  = 1d

# 触发封禁的失败次数阈值
maxretry = 5

# Debian 12+ 使用 systemd 后端
backend = systemd

# 反向 DNS 策略：warn 模式记录但不阻断
usedns = warn

# 告警邮件配置
destemail = ${DEST_EMAIL:-root@local-system}
sender = ${SENDER_EMAIL:-root@system-hostname}
mta = mail

# 封禁动作：发送带 whois 信息的邮件通知
action = %(action_mw)s

protocol = tcp

# 使用 firewallcmd-ipset 作为封禁后端（适配 firewalld）
banaction = firewallcmd-ipset

[sshd]

enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
logpath  = %(sshd_log)s
EOF
}

# 配置 mail-whois.local，定制告警邮件内容
configure_mail_whois() {
  local config_file="/etc/fail2ban/action.d/mail-whois.local"
  cat > "$config_file" <<'EOF'
[INCLUDES]
before = mail-whois-common.conf

[Definition]
norestored = 1
actionstart = printf %%b "🔔 服务启动通知\n\n🖥️ 主机：<fq-hostname>\n⚙️ 服务：<name>\n🕓 时间：$(date '+%%Y-%%m-%%d %%H:%%M:%%S')\n\n📧 此邮件由 Fail2Ban 自动发送，请勿直接回复。\n" | mail -s "[Fail2Ban] <fq-hostname> · <name> 服务已启动" <dest>
actionstop = printf %%b "⚠️ 服务停止通知\n\n🖥️ 主机：<fq-hostname>\n⚙️ 服务：<name>\n🕓 时间：$(date '+%%Y-%%m-%%d %%H:%%M:%%S')\n\n📧 此邮件由 Fail2Ban 自动发送，请勿直接回复。\n" | mail -s "[Fail2Ban] <fq-hostname> · <name> 服务已停止" <dest>
actioncheck =
actionban = printf %%b "🚨 安全警报：检测到暴力攻击\n\n🎯 攻击目标\n🖥️ 主机：<fq-hostname>\n⚙️ 服务：<name>\n\n👤 攻击者信息\n🌍 IP：<ip>\n$(GEO=$(/bin/curl -s --connect-timeout 3 --max-time 5 'http://ip-api.com/json/<ip>' 2>/dev/null); COUNTRY=$(printf '%%s' "$GEO" | grep -o '"country":"[^"]*"' | cut -d'"' -f4); CITY=$(printf '%%s' "$GEO" | grep -o '"city":"[^"]*"' | cut -d'"' -f4); ISP=$(printf '%%s' "$GEO" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4); if [ -n "$CITY" ] && [ -n "$COUNTRY" ]; then LOC="$CITY, $COUNTRY"; elif [ -n "$COUNTRY" ]; then LOC="$COUNTRY"; else LOC="未知"; fi; printf '📍 来源：%%s\n🏢 运营商：%%s' "$LOC" "${ISP:-未知}")\n🔢 攻击次数：<failures> 次\n⏱️ 封禁时长：<bantime> 秒\n\n📋 处置说明\n攻击者 IP <ip> 已加入防火墙黑名单。\n手动解封：fail2ban-client set <name> unbanip <ip>\n\n📧 此邮件由 Fail2Ban 自动发送，请勿直接回复。\n" | mail -s "[Fail2Ban] <fq-hostname> · <name> 疑似遭到暴力攻击" <dest>
actionunban =
[Init]
name = default
dest = root
EOF
}

# 配置 pam-generic，增强 Cockpit 登录防护
configure_pam_generic() {
  local config_file="/etc/fail2ban/jail.d/defaults-debian.conf"
  if ! grep -q "\[pam-generic\]" "$config_file"; then
    printf "\n[pam-generic]\nenabled = true\n" >> "$config_file"
  fi
}

# 启动并启用 Fail2ban 服务，确保防护生效
start_fail2ban() {
  if ! systemctl enable fail2ban >/dev/null 2>&1; then
    log_error "Fail2ban 服务开机自启配置失败，请检查 systemctl 服务状态。"
    exit "${ERROR_GENERAL}"
  fi
  log_info "正在重启 Fail2ban 服务以加载新配置..."
  if ! systemctl restart fail2ban >/dev/null 2>&1; then
    log_error "Fail2ban 服务重启失败，请检查 systemctl 服务状态。"
    exit "${ERROR_GENERAL}"
  fi
  log_success "Fail2ban 服务已启动，并设置为开机自启。"
}

# 主执行流程，串联各功能模块
main() {
  install_fail2ban
  configure_email
  configure_jail_local
  configure_mail_whois
  configure_pam_generic
  start_fail2ban
}

main 
