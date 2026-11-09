#!/bin/bash
# @module: fail2ban
# @name: 配置 Fail2ban
# @category: 安全防护
# @depends:
# @depend_modules: firewall
# @version: 1.0.0
# @order: 42
# 功能：安装并配置 fail2ban 自动封锁服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 跟踪是否有配置变更（决定是否重启服务）
_config_changed=0

# 安装 Fail2ban 软件包，保障安全防护
install_fail2ban() {
  log_info "安装 Fail2ban..."
  apt_install_packages fail2ban
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

# jail.local 由 DebNAS 管理的标识（首行）；无此标识且非旧版 DebNAS 生成的文件视为用户自定义，不覆盖
readonly JAIL_LOCAL_MARKER="# DebNAS managed: 本文件由 DebNAS 生成，自定义配置请放 /etc/fail2ban/jail.d/*.local"

# 检测 sshd 实际监听端口（逗号分隔）；自定义 SSH 端口时 port=ssh 只封 22，封禁形同虚设
get_sshd_ports_csv() {
  local ports="" cfg
  local -a cfgs=()
  if command -v sshd &>/dev/null; then
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}') || ports=""
  fi
  if [[ -z "$ports" ]]; then
    for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
      [[ -f "$cfg" ]] && cfgs+=("$cfg")
    done
    if [[ ${#cfgs[@]} -gt 0 ]]; then
      ports=$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2}' "${cfgs[@]}" 2>/dev/null) || ports=""
    fi
  fi
  [[ -z "$ports" ]] && ports="22"
  printf '%s\n' "$ports" | awk 'NF' | sort -un | paste -sd, -
}

# 本机直连的私有网段（RFC1918），加入 ignoreip 防止管理员在局域网内被误封
# 排除 Docker 网桥（docker0 / br-xxxx），容器网段不应免封
get_local_private_subnets() {
  command -v ip &>/dev/null || return 0
  ip -o -4 route show scope link 2>/dev/null \
    | awk '{dev = ""; for (i = 2; i < NF; i++) if ($i == "dev") dev = $(i + 1)}
           dev ~ /^(docker[0-9]*|br-)/ {next}
           $1 ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ && $1 ~ /\// {print $1}' \
    | sort -u | paste -sd' ' - || true
}

# 判断 jail.local 是否可由 DebNAS 覆盖：不存在 / 带 DebNAS 标识 / 旧版 DebNAS 生成
jail_local_is_managed() {
  local config_file="$1"
  [[ ! -e "$config_file" ]] && return 0
  local first_line
  first_line=$(head -n 1 "$config_file" 2>/dev/null) || first_line=""
  [[ "$first_line" == "$JAIL_LOCAL_MARKER" ]] && return 0
  grep -qF '# 忽略本机流量，防止自身被封禁' "$config_file" 2>/dev/null \
    && grep -qF '# 使用 firewallcmd-ipset 作为封禁后端（适配 firewalld）' "$config_file" 2>/dev/null
}

# 配置 jail.local，定制 fail2ban 行为
configure_jail_local() {
  local config_file="/etc/fail2ban/jail.local"
  if ! jail_local_is_managed "$config_file"; then
    log_warning "检测到用户自定义的 ${config_file}，保留不覆盖（如需 DebNAS 默认配置请先备份并删除该文件）"
    return 0
  fi

  local ssh_ports lan_subnets
  ssh_ports=$(get_sshd_ports_csv)
  lan_subnets=$(get_local_private_subnets)
  log_info "SSH 封禁端口：${ssh_ports}"
  if [[ -n "$lan_subnets" ]]; then
    log_info "局域网白名单（ignoreip）：${lan_subnets}"
  fi

  local content
  content="${JAIL_LOCAL_MARKER}
[DEFAULT]

# 忽略本机及本机直连局域网流量，防止自身被封禁
ignoreip = 127.0.0.1/8 ::1${lan_subnets:+ ${lan_subnets}}

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
port     = ${ssh_ports}
filter   = sshd
backend  = systemd
logpath  = %(sshd_log)s"

  if write_file_if_changed "$config_file" "$content"; then
    _config_changed=1
  fi
}

# 配置 mail-whois.local，定制告警邮件内容
# shellcheck disable=SC2016
# 注：$GEO、$COUNTRY 等变量及 \n、\t 转义序列属于 fail2ban 模板，由 fail2ban 运行时展开
configure_mail_whois() {
  local config_file="/etc/fail2ban/action.d/mail-whois.local"
  local content
  content=$(cat <<'MAIL_EOF'
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
MAIL_EOF
)

  if write_file_if_changed "$config_file" "$content"; then
    _config_changed=1
  fi
}

# 配置 pam-generic，增强 Cockpit 登录防护
configure_pam_generic() {
  local config_file="/etc/fail2ban/jail.d/defaults-debian.conf"
  if ! grep -q "\[pam-generic\]" "$config_file"; then
    printf "\n[pam-generic]\nenabled = true\n" >> "$config_file"
    _config_changed=1
  fi
}

# 启动并启用 Fail2ban 服务，确保防护生效
start_fail2ban() {
  # 确保 firewalld 正在运行（fail2ban 的 firewallcmd-ipset 后端需要它）
  service_ensure firewalld started

  service_ensure fail2ban enabled
  if [[ $_config_changed -eq 1 ]]; then
    log_info "重启 Fail2ban 服务以加载新配置..."
    service_ensure fail2ban restarted
  else
    log_info "配置未变更，跳过 Fail2ban 服务重启"
  fi
  log_success "Fail2ban 就绪"
}

# 主执行流程，串联各功能模块
main() {
  local step=0 total=6

  ui_progress_step $((++step)) "$total" "安装 Fail2ban 软件包"
  install_fail2ban

  ui_progress_step $((++step)) "$total" "配置告警邮箱"
  configure_email

  ui_progress_step $((++step)) "$total" "配置封禁规则 (jail.local)"
  configure_jail_local

  ui_progress_step $((++step)) "$total" "配置告警邮件模板"
  configure_mail_whois

  ui_progress_step $((++step)) "$total" "启用 Cockpit 登录防护"
  configure_pam_generic

  ui_progress_step $((++step)) "$total" "启动 Fail2ban 服务"
  start_fail2ban

  ui_progress_step "$step" "$total" "Fail2ban 安装配置完成" "done"
}

main "$@"
