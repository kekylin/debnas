#!/bin/bash
# @module: mail-account
# @name: 配置邮件账户
# @category: 通知服务
# @depends: exim4
# @version: 1.0.0
# @order: 60
# @interactive: true
# 功能：设置发送邮件账户

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 邮箱打码：保留本地部分前 2 位（不足 3 位只留 1 位）+ 域名
_mail_mask_email() {
  local email="${1:-}" local_part domain
  [[ "$email" == *@* ]] || { printf '***'; return 0; }
  local_part="${email%@*}"
  domain="${email##*@}"
  if [[ ${#local_part} -le 2 ]]; then
    printf '%s***@%s' "${local_part:0:1}" "$domain"
  else
    printf '%s***@%s' "${local_part:0:2}" "$domain"
  fi
}

# 通知邮箱状态：输出 "set|<打码地址>" / "unset|" / "noperm|"（文件存在但当前用户无权读取）
_mail_notify_state() {
  local email="" f
  if email=$(notify_email_get 2>/dev/null) && [[ -n "$email" ]]; then
    printf 'set|%s' "$(_mail_mask_email "$email")"
    return 0
  fi
  for f in "$DEBNAS_NOTIFY_EMAIL_FILE" "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"; do
    [[ -n "$f" && -e "$f" ]] || continue
    if [[ ! -r "$f" ]]; then
      printf 'noperm|'
      return 0
    fi
    break
  done
  printf 'unset|'
}

# 当前 smarthost（未配置输出空）
_mail_current_smarthost() {
  local conf="/etc/exim4/update-exim4.conf.conf"
  [[ -r "$conf" ]] || return 0
  sed -n "s/^[[:space:]]*dc_smarthost='\([^']*\)'.*/\1/p" "$conf" 2>/dev/null | head -n 1 || true
}

# exim4 是否已安装（命令或包）
_mail_exim_installed() {
  command -v exim4 >/dev/null 2>&1 || pkg_is_installed exim4-base
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  if ! _mail_exim_installed; then
    echo "absent|未安装 exim4"
    return 0
  fi
  local smarthost notify notify_kind notify_addr notify_desc
  smarthost=$(_mail_current_smarthost)
  notify=$(_mail_notify_state)
  notify_kind="${notify%%|*}"
  notify_addr="${notify#*|}"
  case "$notify_kind" in
    set)    notify_desc="通知 ${notify_addr}" ;;
    noperm) notify_desc="通知邮箱已设置（需 root 查看）" ;;
    *)      notify_desc="未设置通知邮箱" ;;
  esac
  if [[ -z "$smarthost" ]]; then
    if [[ "$notify_kind" == "unset" ]]; then
      echo "absent|已安装 exim4，未配置 SMTP 中继"
    else
      echo "partial|未配置 SMTP 中继 · ${notify_desc}"
    fi
    return 0
  fi
  if [[ "$notify_kind" == "unset" ]]; then
    echo "partial|SMTP ${smarthost} · 未设置通知邮箱"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet exim4 2>/dev/null; then
    echo "warn|SMTP ${smarthost} · ${notify_desc} · exim4 未运行"
    return 0
  fi
  echo "applied|SMTP ${smarthost} · ${notify_desc}"
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致）
module_plan() {
  local smarthost notify notify_kind legacy="$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  smarthost=$(_mail_current_smarthost)
  notify=$(_mail_notify_state)
  notify_kind="${notify%%|*}"

  if ! _mail_exim_installed; then
    echo "risk|exim4|未安装 exim4：执行前置检查会拦截（需先安装 exim4-daemon-light）"
  fi
  if [[ -n "$smarthost" && "$notify_kind" != "unset" ]] && [[ -r /etc/email-addresses ]]; then
    echo "info|mail-account|已配置（SMTP ${smarthost}）：执行时先询问是否重新配置；--yes 模式直接跳过"
  fi
  echo "info|交互输入|发件邮箱（限 qq/163/126/sina/aliyun/gmail/outlook/yahoo）、SMTP 授权码、通知收件邮箱；cron 模式不执行"
  echo "write|/etc/exim4/update-exim4.conf.conf|satellite 模式 + smarthost；内容变化时原件备份到 /var/backups/debnas/"
  echo "write|/etc/exim4/exim4.conf.localmacros|仅 465 端口写入 REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps（保留其他宏）；原件备份到 /var/backups/debnas/"
  echo "write|/etc/exim4/passwd.client|写入 SMTP 账号与授权码（640 root:Debian-exim）；原件备份到 /var/backups/debnas/"
  echo "write|/etc/email-addresses|root 发件地址映射；原件备份到 /var/backups/debnas/"
  echo "write|${DEBNAS_NOTIFY_EMAIL_FILE}|通知收件邮箱（640 root）；原件备份到 /var/backups/debnas/"
  if [[ -n "$legacy" && ! -L "$legacy" ]]; then
    if [[ -f "$legacy" ]]; then
      echo "write|${legacy}|旧位置普通文件备份到 /var/backups/debnas/ 后替换为指向 ${DEBNAS_NOTIFY_EMAIL_FILE} 的符号链接"
    else
      echo "write|${legacy}|/etc/exim4 存在时创建指向 ${DEBNAS_NOTIFY_EMAIL_FILE} 的兼容符号链接"
    fi
  fi
  echo "info|update-exim4.conf|重新生成 Exim4 运行配置"
  echo "service|exim4|重启"
  echo "info|测试邮件|经 SMTP 服务器向通知邮箱发送一封测试邮件（需联网；失败时模块报错退出）"
  echo "risk|SMTP 授权码|以明文保存在 /etc/exim4/passwd.client（640 root:Debian-exim）；集中备份目录（700 root）中的旧版本同样含授权码"
  return 0
}

main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi
  # 检测当前系统上的实际邮件配置（基于系统文件，非 DebNAS 内部状态标记）
  local current_smarthost="" current_sender="" current_notify=""
  current_smarthost=$(_mail_current_smarthost)
  if [[ -f /etc/email-addresses ]]; then
    current_sender=$(awk '{print $2}' /etc/email-addresses 2>/dev/null || true)
  fi
  current_notify=$(notify_email_get 2>/dev/null) || current_notify=""

  if [[ -n "${current_smarthost}" && -n "${current_sender}" && -n "${current_notify}" ]]; then
    log_info "当前邮件配置："
    log_info "  发件邮箱：${current_sender}"
    log_info "  SMTP 服务器：${current_smarthost}"
    log_info "  通知邮箱：${current_notify}"

    if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
      log_info "非交互模式，邮件账户已配置，跳过"
      return 0
    fi

    [[ "$(ui_confirm "是否重新配置邮件账户？" "当前配置:\n发件邮箱: ${current_sender}\nSMTP: ${current_smarthost}\n通知邮箱: ${current_notify}")" == "0" ]] || {
      log_info "保持现有配置，跳过"
      return 0
    }
    log_info "开始重新配置邮件账户..."
  fi

  _mail_main_flow "$@"
}

# 域名与 SMTP 服务器映射
# 国内主流邮箱
declare -A SMTP_MAP=(
  ["qq.com"]="smtp.qq.com:587"
  ["163.com"]="smtp.163.com:465"
  ["126.com"]="smtp.126.com:465"
  ["sina.com"]="smtp.sina.com:465"
  ["aliyun.com"]="smtp.aliyun.com:465"
  # 国外主流邮箱
  ["gmail.com"]="smtp.gmail.com:587"
  ["outlook.com"]="smtp-mail.outlook.com:587"
  ["yahoo.com"]="smtp.mail.yahoo.com:587"
)

# 交互读取一项必填输入：空值或校验失败时重试，最多 5 次，用尽（含输入流结束）退出
# 参数：$1 - 结果变量名；$2 - 项目名称；$3 - 提示；$4 - 输入模式（hidden 或空）
#       $5 - 校验函数（可选，参数为输入值）；$6 - 校验失败提示
_mail_ask() {
  local -n _mail_ask_out="$1"
  local label="$2" prompt="$3" mode="${4:-}" validator="${5:-}" invalid_msg="${6:-}" attempt value
  for ((attempt = 1; attempt <= 5; attempt++)); do
    value=$(ui_input "$prompt" "" "$mode")
    if [[ -z "$value" ]]; then
      log_error "${label}不能为空"
      continue
    fi
    if [[ -z "$validator" ]] || "$validator" "$value" >/dev/null; then
      _mail_ask_out="$value"
      return 0
    fi
    log_error "$invalid_msg"
  done
  log_error "${label}输入无效次数过多或输入流已结束"
  exit "${ERROR_GENERAL}"
}

# 校验通知邮箱格式
_mail_valid_notify_email() {
  local notify_email="$1"
  [[ "$notify_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# 验证发件邮箱格式与域名匹配（支持 SMTP_MAP 中所有域名）
validate_sender_email() {
  local email="$1" domain smarthost
  domain="${email##*@}"
  smarthost="${SMTP_MAP[$domain]:-}"
  if [[ -n "$smarthost" ]]; then
    printf "%s" "$smarthost"
    return 0
  else
    log_error "不支持的邮箱域名：${domain}。支持的域名：${!SMTP_MAP[*]}"
    return 1
  fi
}

# 将 host:port 转换为 Exim 的 dc_smarthost 写法 host::port
# 说明：Exim 中单冒号是主机列表分隔符，smtp.qq.com:587 会被当成两台主机
#      （smtp.qq.com 走 25 端口 + 名为 587 的主机），端口必须写成双冒号。
# 465 为 SMTPS（连接即 TLS），需模板支持 REMOTE_SMTP_SMARTHOST_PROTOCOL 宏，
# 不支持时回退为不带端口（25 端口 STARTTLS，与旧版实际生效的行为一致）。
# 参数：$1 - host:port
# 输出：Exim smarthost 字符串
to_exim_smarthost() {
  local smarthost="$1" host port
  host="${smarthost%:*}"
  port="${smarthost##*:}"
  if [[ "$host" == "$smarthost" || -z "$port" ]]; then
    printf '%s' "$smarthost"
    return 0
  fi
  if [[ "$port" == "465" ]] \
    && ! grep -q 'REMOTE_SMTP_SMARTHOST_PROTOCOL' /etc/exim4/exim4.conf.template 2>/dev/null; then
    log_warning "当前 Exim4 模板不支持 SMTPS(465)，回退为 ${host} 默认端口（25，STARTTLS）"
    printf '%s' "$host"
    return 0
  fi
  printf '%s::%s' "$host" "$port"
}

# 维护 exim4.conf.localmacros 中的 REMOTE_SMTP_SMARTHOST_PROTOCOL（保留用户其他宏）
# 参数：$1 - exim smarthost（host::465 时启用 smtps，否则移除该宏）
configure_smarthost_protocol() {
  local exim_smarthost="$1"
  local macros_file="/etc/exim4/exim4.conf.localmacros"
  local others="" new_content=""

  if [[ -f "$macros_file" ]]; then
    others=$(grep -v '^[[:space:]]*REMOTE_SMTP_SMARTHOST_PROTOCOL[[:space:]]*=' "$macros_file" 2>/dev/null || true)
  fi
  new_content="$others"
  if [[ "$exim_smarthost" == *"::465" ]]; then
    [[ -n "$others" ]] && new_content="${others}"$'\n'
    new_content+="REMOTE_SMTP_SMARTHOST_PROTOCOL = smtps"
  fi
  if [[ -z "$new_content" ]]; then
    [[ -f "$macros_file" ]] || return 0
    new_content="# DebNAS: no local macros"
  fi
  local wrc=0
  write_file_if_changed "$macros_file" "$new_content" || wrc=$?
  if [[ "$wrc" -eq 2 ]]; then
    log_error "写入 ${macros_file} 失败"
    return 1
  fi
  return 0
}

# 生成 Exim4 邮件服务器配置文件
generate_exim_config() {
  local email_domain="$1" smarthost="$2"
  local exim_smarthost
  exim_smarthost=$(to_exim_smarthost "$smarthost")
  configure_smarthost_protocol "$exim_smarthost" || return 1
  local exim_config="dc_eximconfig_configtype='satellite'
dc_other_hostnames=''
dc_local_interfaces='127.0.0.1 ; ::1'
dc_readhost='$email_domain'
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost='$exim_smarthost'
CFILEMODE='644'
dc_use_split_config='false'
dc_hide_mailname='true'
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'"
  local wrc=0
  write_file_if_changed "/etc/exim4/update-exim4.conf.conf" "$exim_config" || wrc=$?
  if [[ "$wrc" -eq 2 ]]; then
    log_error "写入 /etc/exim4/update-exim4.conf.conf 失败"
    return 1
  fi
  local conf_err
  conf_err=$(update-exim4.conf 2>&1) || {
    log_error "更新 Exim4 配置失败：${conf_err}"
    return 1
  }
}

# 配置 SMTP 认证参数
configure_smtp_auth() {
  local email_domain="$1" email="$2" password="$3" notify_email="$4"
  # 先以 0640 创建/收紧权限再写入，避免密码文件以默认 0644 落盘后再 chmod 的窗口期
  local passwd_file="/etc/exim4/passwd.client"
  if [[ ! -f "$passwd_file" ]]; then
    install -m 0640 /dev/null "$passwd_file"
  fi
  chmod 640 "$passwd_file"
  chown root:Debian-exim "$passwd_file" 2>/dev/null || true
  local wrc=0
  write_file_if_changed "$passwd_file" "*.$email_domain:${email}:${password}" 640 || wrc=$?
  if [[ "$wrc" -eq 2 ]]; then
    log_error "写入 ${passwd_file} 失败"
    return 1
  fi
  wrc=0
  write_file_if_changed "/etc/email-addresses" "root: $email" || wrc=$?
  if [[ "$wrc" -eq 2 ]]; then
    log_warning "写入 /etc/email-addresses 失败，root 发件地址映射可能未生效"
  fi
  # 通知收件邮箱写到 /etc/debnas/notify_email（640 root），旧位置改为符号链接，见 lib/system/layout.sh
  notify_email_set "$notify_email" || log_warning "写入通知邮箱失败：${DEBNAS_NOTIFY_EMAIL_FILE}"
}

# 重启 Exim4 邮件服务
restart_exim_service() {
  log_info "重启 Exim4..."
  service_ensure "exim4" "restarted" || { log_error "Exim4 服务重启失败。"; return 1; }
}

# 发送测试邮件
# 邮件主题按 RFC 2047 编码（UTF-8 Base64）
# 参数：$1 - 主题原文
# 输出：每 10 个字符一个 encoded-word（≤ 40 字节，编码后不超过 75 字符），多段折行续写
_mail_mime_subject() {
  local s="${1-}" out="" i=0 LC_ALL=C.UTF-8
  while (( i < ${#s} )); do
    out+="${out:+$'\n '}=?UTF-8?B?$(printf '%s' "${s:i:10}" | base64 -w0)?="
    i=$((i + 10))
  done
  printf '%s' "$out"
}

send_validation_email() {
  local notify_email="$1" sender_email="$2" smtp_server="$3"
  local os_name version_id codename sys_desc
  os_name=$(_get_os_id 2>/dev/null) || os_name=""
  os_name="${os_name^}"
  version_id=$(_get_os_version_id 2>/dev/null) || version_id=""
  codename=$(get_system_codename 2>/dev/null) || codename=""
  if [[ "$os_name" == "Debian" ]]; then
    if [[ -n "$codename" ]]; then
      sys_desc="Debian ${version_id} (${codename})"
    else
      sys_desc="Debian ${version_id}"
    fi
  else
    if [[ -n "$version_id" ]]; then
      sys_desc="${os_name} ${version_id}"
    else
      sys_desc="${os_name}"
    fi
  fi
  local app_name="DebNAS"
  local email_content
  email_content=$(cat <<EOF
Subject: $(_mail_mime_subject "来自 [${app_name}] 的测试邮件")
To: ${notify_email}
From: ${sender_email}
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

恭喜！您已成功配置 [${app_name}] 的邮件通知功能。
• 系统版本: ${sys_desc}
• SMTP 发件服务器: ${smtp_server}
• 发件邮箱地址: ${sender_email}
• 通知接收邮箱: ${notify_email}
• 配置验证时间: $(date +"%Y-%m-%d %H:%M")

如需了解更多 [${app_name}] 使用方法，请访问 https://github.com/kekylin/debnas

此邮件为系统自动发送，请勿直接回复。
EOF
  )
  log_info "发送测试邮件..."
  # exim4 -oi：正文中单独一行 "." 不会被当作消息结束
  printf '%s\n' "$email_content" | exim4 -oi -bm "$notify_email" && \
    log_success "测试邮件已发送" || \
    { log_error "测试邮件发送失败，请查看 /var/log/exim4/mainlog。"; exit "${ERROR_GENERAL}"; }
}

# 主控制流程（main 完成配置检查后调用）
_mail_main_flow() {
  # 检查 exim4、update-exim4.conf、systemctl 依赖，确保后续操作可用
  REQUIRED_CMDS=(exim4 update-exim4.conf systemctl)
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "缺少 exim4，请先手动安装。"
    exit "${ERROR_DEPENDENCY}"
  fi

log_info "配置邮件服务..."

local email password notify_email smarthost email_domain
_mail_ask email "发件邮箱" "请输入 SMTP 发件邮箱地址" "" validate_sender_email "邮箱域名不支持"
smarthost=$(validate_sender_email "$email")
email_domain="${email##*@}"
_mail_ask password "授权密码" "请输入 SMTP 服务授权密码" "hidden"
_mail_ask notify_email "通知邮箱" "请输入系统通知接收邮箱地址" "" _mail_valid_notify_email "邮箱格式无效"

generate_exim_config "$email_domain" "$smarthost"
configure_smtp_auth "$email_domain" "$email" "$password" "$notify_email"
restart_exim_service
send_validation_email "$notify_email" "$email" "$smarthost"

log_info "服务配置信息："
log_info "• SMTP 发件服务器: ${smarthost}"
log_info "• 发件邮箱地址: ${email}"
log_info "• 通知接收邮箱: ${notify_email}"
log_info "• 配置验证时间: $(date +'%Y-%m-%d %H:%M')"


}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
