#!/bin/bash
# 登录通知 — 启用/禁用逻辑

enable_login_mail() {
  REQUIRED_CMDS=(exim4)
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "缺少 exim4 依赖，请先配置邮件账户并安装 exim4。"
    return 1
  fi

  EMAIL_FILE="/etc/exim4/notify_email"
  if [[ ! -f "$EMAIL_FILE" ]]; then
    log_error "未检测到 $EMAIL_FILE，请先通过「设置发送邮件账户」模块完成配置。"
    return 1
  fi

  read -r notify_email < "$EMAIL_FILE" || {
    log_error "无法读取通知邮箱地址，请检查 $EMAIL_FILE 权限及内容。"
    return 1
  }

  if [[ -z "$notify_email" ]]; then
    log_error "通知邮箱地址为空，请先通过「设置发送邮件账户」模块完成配置。"
    return 1
  fi

  log_info "通知邮箱地址：$notify_email"

  NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
  NOTIFY_SCRIPT_TMP=$(create_temp_file "notify-script" ".sh")
  cat > "$NOTIFY_SCRIPT_TMP" << 'EOF'
#!/bin/bash
# PAM 登录会话开启时发送邮件通知（UTF-8，带地理位置与处置指引）

export LANG="en_US.UTF-8"
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0

# 安全 IFS（不使用 set -e 避免邮件发送失败时脚本退出）
IFS=$'\n\t'

# 读取收件人（作为通知接收方，同时用于 From 头显示）
NOTIFY_EMAIL_FILE="/etc/exim4/notify_email"
NOTIFY_TO=""
if [[ -f "$NOTIFY_EMAIL_FILE" ]]; then
  read -r NOTIFY_TO < "$NOTIFY_EMAIL_FILE" || true
fi
if [[ -z "$NOTIFY_TO" ]]; then
  # 未配置收件人则放弃发送
  exit 0
fi

# 设置成功状态
STATUS_ICON="✅"

# 生成 Trace ID（8位）
TRACE_ID=$(date +%s | sha256sum | cut -c1-8)

# 获取系统版本信息（兼容无 lsb_release 环境）
OS_VERSION=$(lsb_release -rs 2>/dev/null || awk -F= '/^VERSION_ID=/ {print $2}' /etc/os-release | tr -d '"')
CODENAME=$(lsb_release -cs 2>/dev/null || awk -F= '/^VERSION_CODENAME=/ {print $2}' /etc/os-release | tr -d '"')
if [[ "$OS_VERSION" =~ ^1[0-2] ]]; then
  LOGIN_CMD="last -a | head -20"
elif [[ "$OS_VERSION" =~ ^1[3-9] ]]; then
  LOGIN_CMD="wtmpdb last | head -20"
else
  LOGIN_CMD="last -a | head -20"
fi

# 获取主机名
HOSTNAME=$(hostname -s)

# 生成地理位置信息（处理 IPv6 映射 IPv4 情况）
if [[ "${PAM_RHOST:-}" =~ ^::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  IPV4_ADDR="${BASH_REMATCH[1]}"
else
  IPV4_ADDR="${PAM_RHOST:-}"
fi

# 统一的地理位置识别逻辑（无 curl 时降级）
if [[ -z "${IPV4_ADDR}" || "${IPV4_ADDR}" == "localhost" || "${IPV4_ADDR}" == "::1" || "${IPV4_ADDR}" == "127.0.0.1" ]]; then
  LOCATION_INFO="本地登录"
elif [[ "${IPV4_ADDR}" =~ ^192\.168\. ]] || [[ "${IPV4_ADDR}" =~ ^10\. ]] || [[ "${IPV4_ADDR}" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
  LOCATION_INFO="${IPV4_ADDR} (局域网)"
else
  if command -v curl >/dev/null 2>&1; then
    GEO_RESPONSE=$(curl -s --connect-timeout 3 --max-time 5 "http://ip-api.com/json/${IPV4_ADDR}" 2>/dev/null)
    COUNTRY=$(echo "${GEO_RESPONSE}" | grep -o '"country":"[^"]*"' | cut -d '"' -f4)
    CITY=$(echo "${GEO_RESPONSE}" | grep -o '"city":"[^"]*"' | cut -d '"' -f4)
    if [[ -n "${COUNTRY}" ]]; then
      if [[ -n "${CITY}" && "${CITY}" != "${COUNTRY}" ]]; then
        LOCATION_INFO="${IPV4_ADDR} (${CITY}, ${COUNTRY})"
      else
        LOCATION_INFO="${IPV4_ADDR} (${COUNTRY})"
      fi
    else
      LOCATION_INFO="${IPV4_ADDR} (外网)"
    fi
  else
    LOCATION_INFO="${IPV4_ADDR} (外网)"
  fi
fi

{
  echo "To: ${NOTIFY_TO}"
  echo "Subject: 登录通知 · ${PAM_USER} @ ${HOSTNAME}"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Transfer-Encoding: 8bit"
  echo
  echo "🔔 安全通知：检测到新的登录会话"
  echo
  echo "👤 用户：${PAM_USER}"
  echo "🌍 来源：${LOCATION_INFO}"
  echo "🖥️ 主机：${HOSTNAME}"
  echo "🕓 时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "⚙️ 服务：${PAM_SERVICE}"
  echo "💻 终端：${PAM_TTY}"
  echo
  echo "⚠️ 处置指引"
  echo "如非授权登录，请按以下步骤处理："
  echo
  echo "🚨 立即行动（5分钟内）"
  echo "- 锁定账户：sudo passwd -l ${PAM_USER}"
  echo "- 断开连接：sudo pkill -KILL -u ${PAM_USER}"
  echo
  echo "🔍 调查分析（30分钟内）"
  echo "- 登录记录：${LOGIN_CMD}"
  echo
  echo "📧 系统通知 · Trace ID ${TRACE_ID}"
  echo "此邮件由系统自动生成，请勿直接回复。"
} | /usr/sbin/exim4 -t || true
EOF

  if [[ ! -f "$NOTIFY_SCRIPT" ]] || ! cmp -s "$NOTIFY_SCRIPT_TMP" "$NOTIFY_SCRIPT"; then
    mv "$NOTIFY_SCRIPT_TMP" "$NOTIFY_SCRIPT"
    chmod 755 "$NOTIFY_SCRIPT"
    chown root:root "$NOTIFY_SCRIPT"
    log_info "登录通知脚本已更新。"
  else
    rm -f "$NOTIFY_SCRIPT_TMP"
  fi

  PAM_FILE="/etc/pam.d/common-session"
  if ! grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
    echo "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" >> "$PAM_FILE"
    log_success "登录通知已启用"
    module_mark_action
  else
    log_info "登录通知已配置，无需重复操作"
  fi
}

disable_login_mail() {
  NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"
  PAM_FILE="/etc/pam.d/common-session"

  if grep -Fxq "session optional pam_exec.so debug /bin/bash $NOTIFY_SCRIPT" "$PAM_FILE" 2>/dev/null; then
    sed -i "/session optional pam_exec.so debug \/bin\/bash \/etc\/pam.d\/login-notify.sh/d" "$PAM_FILE"
    log_success "登录通知已移除"
    module_mark_action
  else
    log_info "登录通知未配置"
  fi

  if [ -f "$NOTIFY_SCRIPT" ]; then
    rm -f "$NOTIFY_SCRIPT"
    log_info "已删除登录通知脚本 $NOTIFY_SCRIPT。"
  fi
}
