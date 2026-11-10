#!/bin/bash
# 登录通知 — 启用/禁用逻辑

enable_login_mail() {
  if ! check_dependencies exim4; then
    log_error "缺少 exim4 依赖，请先配置邮件账户并安装 exim4。"
    return 1
  fi

  local notify_email=""
  if ! notify_email=$(notify_email_get); then
    log_error "未配置通知邮箱（$(notify_email_file) 不存在或为空），请先通过「设置发送邮件账户」模块完成配置。"
    return 1
  fi

  log_info "通知邮箱地址：$notify_email"

  # 脚本放在 DebNAS 自有目录（旧版位于 /etc/pam.d/login-notify.sh，由 migration.sh 迁移）
  local NOTIFY_SCRIPT="$DEBNAS_LOGIN_NOTIFY_SCRIPT" PAM_FILE="$DEBNAS_PAM_SESSION_FILE"
  local script_content=""
  IFS= read -r -d '' script_content << 'EOF' || true
#!/bin/bash
# PAM 登录会话开启时发送邮件通知（UTF-8，带地理位置与处置指引）

export LANG="en_US.UTF-8"
[ "${PAM_TYPE:-}" = "open_session" ] || exit 0

# 安全 IFS（不使用 set -e 避免邮件发送失败时脚本退出）
IFS=$'\n\t'

# 读取收件人（新位置优先，旧位置兼容回退；路径由 DebNAS 生成脚本时填入）
NOTIFY_TO=""
for NOTIFY_EMAIL_FILE in "__DEBNAS_NOTIFY_EMAIL_FILE__" "__DEBNAS_LEGACY_NOTIFY_EMAIL_FILE__"; do
  if [[ -f "$NOTIFY_EMAIL_FILE" ]]; then
    read -r NOTIFY_TO < "$NOTIFY_EMAIL_FILE" || true
    break
  fi
done
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

# 邮件主题按 RFC 2047 编码（UTF-8 Base64）：每 10 个字符一个 encoded-word（≤ 40 字节，
# 编码后不超过 75 字符），多段之间折行续写；按字符切分，不会把多字节字符截断
mime_subject() {
  local s="${1-}" out="" i=0 LC_ALL=C.UTF-8
  while (( i < ${#s} )); do
    out+="${out:+$'\n '}=?UTF-8?B?$(printf '%s' "${s:i:10}" | base64 -w0)?="
    i=$((i + 10))
  done
  printf '%s' "$out"
}

# 以下地理位置查询与邮件发送放到后台执行：pam_exec 会同步等待本脚本退出，
# 同步执行会让每次登录多等数秒（网络查询 + exim 投递）。
send_login_notify() {

# 生成地理位置信息（处理 IPv6 映射 IPv4 情况）
if [[ "${PAM_RHOST:-}" =~ ^::ffff:([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  IPV4_ADDR="${BASH_REMATCH[1]}"
else
  IPV4_ADDR="${PAM_RHOST:-}"
fi

# 统一的地理位置识别逻辑（无 curl 时降级）
# 隐私：ip-api.com 免费接口仅支持明文 HTTP，会把登录来源 IP 发给第三方。
# 默认不查询，需在 /etc/debnas/debnas.conf 中设置 login_mail_geoip=1 才启用。
GEOIP_ENABLED=0
if grep -qE '^[[:space:]]*login_mail_geoip[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/debnas/debnas.conf 2>/dev/null; then
  GEOIP_ENABLED=1
fi
if [[ -z "${IPV4_ADDR}" || "${IPV4_ADDR}" == "localhost" || "${IPV4_ADDR}" == "::1" || "${IPV4_ADDR}" == "127.0.0.1" ]]; then
  LOCATION_INFO="本地登录"
elif [[ "${IPV4_ADDR}" =~ ^192\.168\. ]] || [[ "${IPV4_ADDR}" =~ ^10\. ]] || [[ "${IPV4_ADDR}" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then
  LOCATION_INFO="${IPV4_ADDR} (局域网)"
else
  if [[ "${GEOIP_ENABLED}" -eq 1 ]] && command -v curl >/dev/null 2>&1; then
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
  echo "Subject: $(mime_subject "登录通知 · ${PAM_USER} @ ${HOSTNAME}")"
  echo "MIME-Version: 1.0"
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
} | /usr/sbin/exim4 -oi -t || true
}

# PAM 同步调用时：用 setsid -f 在新会话中重新执行本脚本（--send）后立即返回，不阻塞登录；
# 发送进程完全脱离登录会话与控制终端，会话结束的 SIGHUP 不会把它连带杀掉。
# exim4 -oi：正文中单独一行 "." 不会被当作消息结束
if [[ "${1:-}" == "--send" ]]; then
  send_login_notify </dev/null >/dev/null 2>&1
elif command -v setsid >/dev/null 2>&1; then
  setsid -f /bin/bash "$0" --send </dev/null >/dev/null 2>&1 || true
else
  send_login_notify </dev/null >/dev/null 2>&1 &
fi
exit 0
EOF

  script_content="${script_content%$'\n'}"
  script_content="${script_content//__DEBNAS_NOTIFY_EMAIL_FILE__/${DEBNAS_NOTIFY_EMAIL_FILE}}"
  script_content="${script_content//__DEBNAS_LEGACY_NOTIFY_EMAIL_FILE__/${DEBNAS_LEGACY_NOTIFY_EMAIL_FILE}}"

  # 目录 755 root，脚本 750 root（PAM 行带 seteuid，pam_exec 以 root 身份通过 /bin/bash 调用；
  # 普通用户 su / pkexec 提权时同样以 root 运行，读得到本脚本和 640 的通知邮箱）
  local script_dir rc=0
  script_dir="${NOTIFY_SCRIPT%/*}"
  if ! mkdir -p -- "$script_dir"; then
    log_error "创建目录失败：${script_dir}"
    return 1
  fi
  chmod 755 -- "$script_dir" 2>/dev/null || true
  chown root:root -- "$script_dir" 2>/dev/null || true
  write_file_if_changed "$NOTIFY_SCRIPT" "$script_content" 750 1 || rc=$?
  case "$rc" in
    0) log_info "登录通知脚本已更新：${NOTIFY_SCRIPT}" ;;
    2) log_error "写入登录通知脚本失败：${NOTIFY_SCRIPT}"; return 1 ;;
  esac
  chmod 750 -- "$NOTIFY_SCRIPT" 2>/dev/null || true
  chown root:root -- "$NOTIFY_SCRIPT" 2>/dev/null || true

  # PAM 行：旧路径（/etc/pam.d/login-notify.sh）的行原位替换为新路径，保证只有一条
  rc=0
  login_notify_pam_sync "$NOTIFY_SCRIPT" "$PAM_FILE" || rc=$?
  case "$rc" in
    0)
      log_success "登录通知已启用"
      module_mark_action
      ;;
    1) log_info "登录通知已配置，无需重复操作" ;;
    *) log_error "更新 ${PAM_FILE} 失败"; return 1 ;;
  esac

  # 旧位置脚本已不再被 PAM 引用：移入集中备份后删除
  if [[ -f "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" ]] \
    && ! login_notify_pam_references "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" "$PAM_FILE"; then
    debnas_backup_file "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" >/dev/null 2>&1 || true
    rm -f -- "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" 2>/dev/null || true
  fi
}

disable_login_mail() {
  local PAM_FILE="$DEBNAS_PAM_SESSION_FILE" rc=0

  # 新旧两种路径的 pam_exec 行一并移除
  login_notify_pam_sync "" "$PAM_FILE" || rc=$?
  case "$rc" in
    0)
      log_success "登录通知已移除"
      module_mark_action
      ;;
    1) log_info "登录通知未配置" ;;
    *) log_error "更新 ${PAM_FILE} 失败，保留登录通知脚本"; return 1 ;;
  esac

  local script
  for script in "$DEBNAS_LOGIN_NOTIFY_SCRIPT" "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"; do
    if [[ -n "$script" && -f "$script" ]]; then
      rm -f -- "$script"
      log_info "已删除登录通知脚本 ${script}。"
    fi
  done
}
