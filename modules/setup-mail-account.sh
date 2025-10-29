#!/bin/bash
# 功能：设置发送邮件账户

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 exim4、update-exim4.conf、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(exim4 update-exim4.conf systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 exim4，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 域名与 SMTP 服务器映射
declare -A SMTP_MAP=(
  ["qq.com"]="smtp.qq.com:587"
)

# 用户输入提示
prompt_message() {
  echo -e "$1"
}

# 安全文件写入
safe_write() {
  local file="$1" content="$2"
  echo "$content" > "$file" || { log_error "写入文件 $file 失败。"; return 1; }
  return 0
}

# 验证发件邮箱格式与域名匹配
validate_sender_email() {
  local email="$1"
  if [[ "$email" =~ ^[a-zA-Z0-9._%+-]{1,64}@qq\.com$ && "${email##*@}" == "qq.com" ]]; then
    printf "%s" "${SMTP_MAP[qq.com]}"
    return 0
  else
    log_error "无效的 SMTP 发件邮箱地址，仅支持 qq.com 域名。"
    return 1
  fi
}

# 生成 Exim4 邮件服务器配置文件
generate_exim_config() {
  local email_domain="$1" smarthost="$2"
  safe_write "/etc/exim4/update-exim4.conf.conf" "$(cat <<EOF
dc_eximconfig_configtype='satellite'
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
dc_localdelivery='mail_spool'
EOF
)" || exit "${ERROR_GENERAL}"
  if ! update-exim4.conf >/dev/null 2>&1; then
    log_error "更新 Exim4 配置失败，可能会影响后续操作。"
  fi
}

# 配置 SMTP 认证参数
configure_smtp_auth() {
  local email_domain="$1" email="$2" password="$3" notify_email="$4"
  safe_write "/etc/exim4/passwd.client" "*.$email_domain:${email}:${password}" || exit "${ERROR_GENERAL}"
  chown root:Debian-exim "/etc/exim4/passwd.client"
  chmod 640 "/etc/exim4/passwd.client"
  safe_write "/etc/email-addresses" "root: $email" || exit "${ERROR_GENERAL}"
  safe_write "/etc/exim4/notify_email" "$notify_email" || exit "${ERROR_GENERAL}"
  chmod 644 "/etc/exim4/notify_email"
}

# 重启 Exim4 邮件服务
restart_exim_service() {
  log_action "正在重启 Exim4 邮件服务..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart exim4 && systemctl is-active --quiet exim4 || { log_error "Exim4 服务重启失败。"; exit "${ERROR_GENERAL}"; }
  elif command -v service >/dev/null 2>&1; then
    service exim4 restart || { log_error "Exim4 服务重启失败。"; exit "${ERROR_GENERAL}"; }
  else
    log_error "未找到可用的服务管理工具。"
    exit "${ERROR_GENERAL}"
  fi
  log_success "Exim4 服务运行状态已更新。"
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
  log_action "正在发送测试邮件..."
  echo -e "$email_content" | exim -bm "$notify_email" && \
    log_success "测试邮件已成功发送至 ${notify_email}" || \
    { log_fail "测试邮件发送失败，请查看 /var/log/exim4/mainlog。"; exit "${ERROR_GENERAL}"; }
}

# 主控制流程
log_action "开始 Exim4 邮件服务配置..."

prompt_message "请输入 SMTP 发件邮箱地址（仅支持 QQ 域名邮箱）："
email=""
smarthost=""
while read -r email; do
  smarthost=$(validate_sender_email "$email")
  if [[ $? -eq 0 ]]; then
    break
  fi
  prompt_message "请输入有效的 QQ 邮箱地址："
done

email_domain="${email##*@}"
prompt_message "请输入 SMTP 服务授权密码："
password=""
while read -rs password && [[ -z "$password" ]]; do
  log_fail "SMTP 授权密码为必填项。"
  prompt_message "请输入 SMTP 服务授权密码："
done
echo

prompt_message "请输入系统通知接收邮箱地址："
notify_email=""
while read -r notify_email && [[ ! "$notify_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
  log_fail "通知邮箱地址格式无效或为空。"
  prompt_message "请输入有效的通知接收邮箱地址："
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
