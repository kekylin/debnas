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

# 检查文件是否存在且可读，避免后续操作失败
check_file() {
  local file="$1"
  if [[ ! -r "$file" ]]; then
    log_error "目标文件 $file 不存在或无读取权限。"
    return 1
  fi
  return 0
}

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
    dest_email=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$notify_file")
  else
    log_warn "未找到 $notify_file，使用默认接收邮箱 $default_recipient。"
    dest_email="$default_recipient"
  fi

  if [[ -r "$email_file" ]]; then
    sender_email=$(sed -n 's/^root:[[:space:]]*\(.*\)/\1/p' "$email_file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
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
  cp /etc/fail2ban/jail.conf "$config_file"
  cat > "$config_file" <<EOF
# 全局设置
[DEFAULT]

# 此参数标识应被禁止系统忽略的 IP 地址。默认情况下，这只是设置为忽略来自机器本身的流量，这样您就不会填写自己的日志或将自己锁定。
ignoreip = 127.0.0.1/8 ::1

# 此参数设置禁令的长度，以秒为单位。默认值为1h，值为"bantime  = -1"表示将永久禁止IP地址，设置值为1h，则禁止1小时。
bantime  = 1h

# 此参数设置Fail2ban 在查找重复失败的身份验证尝试时将关注的窗口。默认设置为 1d ，这意味着软件将统计最近1 天内的失败尝试次数。
findtime  = 1d

# 这设置了在禁止之前在窗口内允许的失败尝试次数。
maxretry = 5

# 此条目指定Fail2ban 将如何监视日志文件。设置auto意味着 fail2ban 将尝试pyinotify, 然后gamin, 然后基于可用的轮询算法。inotify是一个内置的 Linux 内核功能，用于跟踪文件何时被访问，并且是Fail2ban 使用pyinotify的Python 接口。
# backend = auto
# Debian12使用systemd才能正常启动fail2ban
backend = systemd

# 这定义了是否使用反向 DNS 来帮助实施禁令。将此设置为"否"将禁止 IP 本身而不是其域主机名。该warn设置将尝试查找主机名并以这种方式禁止，但会记录活动以供审查。
usedns = warn

# 如果将您的操作配置为邮件警报，这是接收通知邮件的地址。
destemail = ${DEST_EMAIL:-root@local-system}

# 发送者邮件地址
sender = ${SENDER_EMAIL:-root@system-hostname}

# 这是用于发送通知电子邮件的邮件传输代理。
mta = mail

# "action_"之后的"mw"告诉Fail2ban 向您发送电子邮件。"mwl"也附加了日志。
action = %(action_mw)s

# 这是实施 IP 禁令时将丢弃的流量类型。这也是发送到iptables 链的流量类型。
protocol = tcp

# 这里banaction必须用firewallcmd-ipset,这是firewalll支持的关键，如果是用Iptables请不要这样填写。
banaction = firewallcmd-ipset

[SSH]

enabled     = true
port        = ssh
filter      = sshd
# logpath     = /var/log/auth.log
backend     = systemd
logpath     = %(sshd_log)s
EOF
}

# 配置 mail-whois.local，定制告警邮件内容
configure_mail_whois() {
  local config_file="/etc/fail2ban/action.d/mail-whois.local"
  cp /etc/fail2ban/action.d/mail-whois.conf "$config_file"
  cat > "$config_file" <<'EOF'
[INCLUDES]
before = mail-whois-common.conf

[Definition]
norestored = 1
actionstart = printf %%b "主机名称：<fq-hostname>\n服务名称：<name>\n事件类型：服务启动\n触发时间：$(date "+%%Y-%%m-%%d %%H:%%M:%%S")\n如需获取更多信息，请登录服务器核查！\n\n本邮件由 Fail2Ban 自动发送，请勿直接回复。" | mail -s "[Fail2Ban] <fq-hostname> 主机 <name> 服务已启动！" <dest>
actionstop = printf %%b "主机名称：<fq-hostname>\n服务名称：<name>\n事件类型：服务停止\n触发时间：$(date "+%%Y-%%m-%%d %%H:%%M:%%S")\n如需获取更多信息，请登录服务器核查！\n\n本邮件由 Fail2Ban 自动发送，请勿直接回复。" | mail -s "[Fail2Ban] <fq-hostname> 主机 <name> 服务已停止！" <dest>
actioncheck =
actionban = printf %%b "安全警报！！\n被攻击服务：<name>\n被攻击主机名称：$(uname -n)\n被攻击主机IP：$(/bin/curl -s ifconfig.co)\n\n攻击者IP：<ip>\n攻击次数：<failures> 次\n攻击方法：暴力破解，尝试弱口令\n攻击者IP地址 <ip> 已经被Fail2Ban 加入防火墙黑名单，屏蔽时间<bantime>秒。\n以下是攻击者<ip> 信息 :\n$(/bin/curl -s https://api.vore.top/api/IPdata?ip=<ip>)\n\n本邮件由 Fail2Ban 自动发送，请勿直接回复。"|/bin/mailx -s "[Fail2Ban] <fq-hostname> 主机 <name> 服务疑似遭到暴力攻击！" <dest>
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
    echo -e "[pam-generic]\nenabled = true" >> "$config_file"
  fi
}

# 启动并启用 Fail2ban 服务，确保防护生效
start_fail2ban() {
  if ! systemctl enable fail2ban >/dev/null 2>&1; then
    log_error "Fail2ban 服务开机自启配置失败，请检查 systemctl 服务状态。"
    exit "${ERROR_GENERAL}"
  fi
  log_info "正在启动 Fail2ban 服务..."
  if ! systemctl start fail2ban >/dev/null 2>&1; then
    log_error "Fail2ban 服务启动失败，请检查 systemctl 服务状态。"
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
