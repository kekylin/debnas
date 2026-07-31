#!/bin/bash
# @module: mail-account
# @name: 邮件账户
# @category: 通知服务
# @depends: exim4
# @version: 1.0.0
# @order: 60
# 功能：设置发送邮件账户

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi
  # 检测当前系统上的实际邮件配置（基于系统文件，非 DebNAS 内部状态标记）
  local current_smarthost="" current_sender="" current_notify=""
  if [[ -f /etc/exim4/update-exim4.conf.conf ]]; then
    current_smarthost=$(grep -oP "dc_smarthost='\K[^']*" /etc/exim4/update-exim4.conf.conf 2>/dev/null || true)
  fi
  if [[ -f /etc/email-addresses ]]; then
    current_sender=$(awk '{print $2}' /etc/email-addresses 2>/dev/null || true)
  fi
  if [[ -f /etc/exim4/notify_email ]]; then
    current_notify=$(head -1 /etc/exim4/notify_email 2>/dev/null || true)
  fi

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

# 检查 exim4、update-exim4.conf、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(exim4 update-exim4.conf systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 exim4，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

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

# 用户输入提示
prompt_message() {
  printf '%b\n' "$1"
}

# 安全文件写入（避免内容出现在进程参数列表中）
safe_write() {
  local file="$1" content="$2"
  printf '%s\n' "$content" > "$file" || { log_error "写入文件 $file 失败。"; return 1; }
  return 0
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

# 生成 Exim4 邮件服务器配置文件
generate_exim_config() {
  local email_domain="$1" smarthost="$2"
  local exim_config="dc_eximconfig_configtype='satellite'
dc_other_hostnames=''
dc_local_interfaces='127.0.0.1 ; ::1'
dc_readhost='$email_domain'
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost='$smarthost'
CFILEMODE='644'
dc_use_split_config='false'
dc_hide_mailname='true'
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'"
  write_file_if_changed "/etc/exim4/update-exim4.conf.conf" "$exim_config" || true
  local conf_err
  conf_err=$(update-exim4.conf 2>&1) || {
    log_error "更新 Exim4 配置失败：${conf_err}"
    return 1
  }
}

# 配置 SMTP 认证参数
configure_smtp_auth() {
  local email_domain="$1" email="$2" password="$3" notify_email="$4"
  write_file_if_changed "/etc/exim4/passwd.client" "*.$email_domain:${email}:${password}" 640 || true
  chown root:Debian-exim "/etc/exim4/passwd.client" 2>/dev/null || true
  write_file_if_changed "/etc/email-addresses" "root: $email" || true
  write_file_if_changed "/etc/exim4/notify_email" "$notify_email" || true
}

# 重启 Exim4 邮件服务
restart_exim_service() {
  log_info "重启 Exim4..."
  service_ensure "exim4" "restarted" || { log_error "Exim4 服务重启失败。"; return 1; }
}

# 发送测试邮件
send_validation_email() {
  local notify_email="$1" sender_email="$2" smtp_server="$3"
  local os_name version_id codename sys_desc
  os_name="$(awk -F= '/^ID=/ {print $2}' /etc/os-release | sed 's/"//g' | { read name; echo "${name^}"; })"
  version_id="$(awk -F= '/^VERSION_ID=/ {print $2}' /etc/os-release | sed 's/"//g')"
  codename="$(awk -F= '/^VERSION_CODENAME=/ {print $2}' /etc/os-release | sed 's/"//g')"
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
Subject: 来自 [${app_name}] 的测试邮件
To: ${notify_email}
From: ${sender_email}

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
  printf '%s\n' "$email_content" | exim4 -bm "$notify_email" && \
    log_success "测试邮件已发送" || \
    { log_error "测试邮件发送失败，请查看 /var/log/exim4/mainlog。"; exit "${ERROR_GENERAL}"; }
}

# 主控制流程
log_info "配置邮件服务..."

# 读取发件邮箱
email_domain=""
smarthost=""
while true; do
  email=$(ui_input "请输入 SMTP 发件邮箱地址")
  if [[ -z "$email" ]]; then
    log_error "发件邮箱不能为空"
    continue
  fi
  smarthost=$(validate_sender_email "$email") || true
  if [[ -n "$smarthost" ]]; then
    email_domain="${email##*@}"
    break
  fi
  log_error "邮箱域名不支持"
done

# 读取授权密码
while true; do
  password=$(ui_input "请输入 SMTP 服务授权密码" "" "hidden")
  if [[ -z "$password" ]]; then
    log_error "授权密码不能为空"
    continue
  fi
  break
done

# 读取通知接收邮箱
while true; do
  notify_email=$(ui_input "请输入系统通知接收邮箱地址")
  if [[ -z "$notify_email" ]]; then
    log_error "通知邮箱不能为空"
    continue
  fi
  if [[ "$notify_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    break
  fi
  log_error "邮箱格式无效"
done

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

main "$@"
