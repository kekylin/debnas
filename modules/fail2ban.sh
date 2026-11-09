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
  local email_file="/etc/email-addresses"
  local default_recipient="root@local-system"
  local default_sender="root@system-hostname"
  local dest_email sender_email

  # 通知收件邮箱：/etc/debnas/notify_email（旧位置 /etc/exim4/notify_email 回退），见 lib/system/layout.sh
  if ! dest_email=$(notify_email_get); then
    log_warning "未找到 $(notify_email_file)，使用默认接收邮箱 $default_recipient。"
    dest_email="$default_recipient"
  fi

  if [[ -r "$email_file" ]]; then
    sender_email=$(sed -n '/^root:/{s/^root:[[:space:]]*//; s/[[:space:]]*$//; p}' "$email_file")
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

# 本机直连的私有网段（RFC1918），仅在 debnas.conf 设 fail2ban_ignore_lan=1 时加入 ignoreip
# 默认不加：局域网内被攻陷的设备（或经端口映射/反代进来、源地址显示为内网的流量）也应被封禁
# 排除虚拟网桥与 VPN 接口（docker0、br-*、virbr*、lxcbr*、podman*、wg*、veth*、tun*/tap* 等），其网段不应免封
get_local_private_subnets() {
  command -v ip &>/dev/null || return 0
  ip -o -4 route show scope link 2>/dev/null \
    | awk '{dev = ""; for (i = 2; i < NF; i++) if ($i == "dev") dev = $(i + 1)}
           dev ~ /^(docker|br-|virbr|lxcbr|lxdbr|podman|cni|flannel|cali|veth|wg|tun|tap|tailscale|zt)/ {next}
           $1 ~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ && $1 ~ /\// {print $1}' \
    | sort -u | paste -sd' ' - || true
}

# 计算 ignoreip 中追加的局域网段：默认空；fail2ban_ignore_lan=1 时为本机直连私网段
fail2ban_ignore_lan_subnets() {
  if config_get_bool fail2ban_ignore_lan 0; then
    get_local_private_subnets
  fi
  return 0
}

# 判断 jail.local 是否可由 DebNAS 覆盖：不存在 / 带 DebNAS 标识 / 旧版 DebNAS 生成
jail_local_is_managed() {
  local config_file="$1"
  [[ ! -e "$config_file" ]] && return 0
  local first_line=""
  IFS= read -r first_line 2>/dev/null < "$config_file" || true
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
  # 自定义 SSH 端口时 port=ssh 只封 22，封禁形同虚设；--no-session：只取 sshd 配置的端口
  ssh_ports=$(sshd_listen_ports_csv --no-session)
  lan_subnets=$(fail2ban_ignore_lan_subnets)
  log_info "SSH 封禁端口：${ssh_ports}"
  if [[ -n "$lan_subnets" ]]; then
    log_info "局域网白名单（ignoreip，fail2ban_ignore_lan=1）：${lan_subnets}"
  else
    log_info "白名单（ignoreip）仅本机回环；如需放行本机直连局域网，在 debnas.conf 设 fail2ban_ignore_lan=1 后重跑"
  fi

  local content
  content="${JAIL_LOCAL_MARKER}
[DEFAULT]

# 忽略本机流量，防止自身被封禁（debnas.conf 设 fail2ban_ignore_lan=1 时另加本机直连局域网）
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

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 列出运行中的 jail（逗号分隔）；需要 root（fail2ban 控制套接字仅 root 可写）
# 返回：0 成功（stdout 为 jail 列表，可能为空），1 无权限/查询失败
_f2b_running_jails() {
  local sock="/var/run/fail2ban/fail2ban.sock" out=""
  [[ -S "$sock" && -w "$sock" ]] || return 1
  command -v fail2ban-client &>/dev/null || return 1
  out=$(timeout 2 fail2ban-client status 2>/dev/null) || return 1
  out=$(sed -n 's/^.*Jail list:[[:space:]]*//p' <<< "$out" | tr -d '[:space:]') || out=""
  printf '%s' "$out"
}

# 当前状态：一行 "状态码|说明"
module_status() {
  if ! pkg_is_installed fail2ban; then
    echo "absent|未安装 fail2ban"
    return 0
  fi
  if ! service_is_active fail2ban; then
    echo "warn|已安装但 fail2ban 未运行"
    return 0
  fi
  local jails=""
  if jails=$(_f2b_running_jails); then
    if [[ ",${jails}," != *",sshd,"* ]]; then
      echo "warn|运行中，但 sshd jail 未启用（jail：${jails:-无}）"
    elif [[ ",${jails}," != *",pam-generic,"* ]]; then
      echo "partial|运行中 · jail：${jails}（未启用 pam-generic/Cockpit 防护）"
    else
      echo "running|运行中 · jail：${jails}"
    fi
    return 0
  fi
  # 非 root：读不到控制套接字，退回配置文件判断
  local first_line=""
  [[ -r /etc/fail2ban/jail.local ]] && { IFS= read -r first_line < /etc/fail2ban/jail.local || true; }
  if [[ "$first_line" == *"$JAIL_LOCAL_MARKER"* ]]; then
    echo "running|运行中 · DebNAS jail.local 已写入（jail 运行详情需 root 查看）"
  else
    echo "running|运行中（jail 详情需 root 查看）"
  fi
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致）
module_plan() {
  local IFS=$' \n\t'
  local jail_local="/etc/fail2ban/jail.local"
  local defaults="/etc/fail2ban/jail.d/defaults-debian.conf"

  if pkg_is_installed fail2ban; then
    echo "info|fail2ban|已安装，跳过安装"
  else
    echo "pkg|fail2ban|apt 安装"
  fi

  if jail_local_is_managed "$jail_local"; then
    echo "write|${jail_local}|DebNAS 默认规则（sshd 端口 $(sshd_listen_ports_csv --no-session)，封禁 1h/5 次/1d，firewallcmd-ipset）；内容未变则跳过，旧文件备份到 /var/backups/debnas/"
  else
    echo "info|${jail_local}|检测到用户自定义文件，保留不覆盖"
  fi
  echo "write|/etc/fail2ban/action.d/mail-whois.local|告警邮件模板；内容未变则跳过，旧文件备份到 /var/backups/debnas/"

  if [[ -r "$defaults" ]] && grep -q '\[pam-generic\]' "$defaults" 2>/dev/null; then
    echo "info|${defaults}|已启用 pam-generic（已满足）"
  else
    echo "write|${defaults}|追加 [pam-generic] enabled = true（Cockpit 登录防护；直接追加，不另做备份）"
  fi

  if ! service_is_active firewalld; then
    if pkg_is_installed firewalld; then
      echo "service|firewalld|启动（firewallcmd-ipset 封禁后端需要）"
    else
      echo "risk|firewalld|未安装 firewalld，封禁后端不可用，启动步骤会失败；请先执行 firewall 模块"
    fi
  fi
  echo "service|fail2ban|设为开机自启；配置有变更时重启"
  local lan="" white="仅本机回环（局域网同样会被封，可在 debnas.conf 设 fail2ban_ignore_lan=1 放行直连网段）"
  lan=$(fail2ban_ignore_lan_subnets)
  [[ -n "$lan" ]] && white="本机及直连局域网 ${lan}（fail2ban_ignore_lan=1）"
  echo "risk|封禁|同一 IP 1 天内失败 5 次封禁 1 小时；白名单${white}，管理员多次输错密码也会被封"
  echo "info|告警邮件|每次封禁发送邮件（需已配置邮件发送，见 mail-account 模块）"
  return 0
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
