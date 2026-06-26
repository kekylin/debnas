#!/bin/bash
# check-system-updates: 定时检查逻辑
set -euo pipefail
IFS=$'\n\t'
setup_script_file() {
  local current_script=$(readlink -f "$0")
  USER_HOME=$(eval echo ~$USER)
  local script_path="$USER_HOME/.system-update-checker.sh"
  # 生成独立可运行的轻量脚本（不依赖项目目录与公共库）
  cat > "$script_path" <<'EOF'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
export LANG="C.UTF-8"; export LC_ALL="C.UTF-8"

# 轻量日志
log_action(){ printf "[ACTION] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
log_success(){ printf "[SUCCESS] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
log_error(){ printf "[FAIL] %s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2; }

EMAIL_CONFIG_FILE="/etc/exim4/notify_email"

get_email(){
  [[ -f "$EMAIL_CONFIG_FILE" ]] || { log_error "未找到 $EMAIL_CONFIG_FILE"; exit 3; }
  local to
  read -r to < "$EMAIL_CONFIG_FILE" || true
  [[ -n "$to" ]] || { log_error "通知邮箱为空"; exit 3; }
  echo "$to"
}

# 解析 Inst 行并分组
format_inst_lines(){
  awk '
  /^Inst / {
    if (match($0, /^Inst[[:space:]]+([^[:space:]]+)[[:space:]]+\[([^\]]+)\][[:space:]]+\(([^[:space:]]+)/, m)) {
      printf "%s\n   ↳ %s → %s\n\n", m[1], m[2], m[3];
    }
  }'
}

run_check(){
  log_action "正在生成系统更新报告"
  apt-get update > /dev/null 2>&1 || true
  local full
  full=$(apt-get upgrade -s)
  security_list=$(echo "$full" | grep -E '^Inst' | grep -i 'Debian-Security\|security' || true)
  regular_list=$(echo "$full" | grep -E '^Inst' | grep -vi 'Debian-Security\|security' || true)
  security_count=$(echo "$security_list" | grep -c '^Inst' || true)
  regular_count=$(echo "$regular_list" | grep -c '^Inst' || true)
}

build_report(){
  local total=$((security_count + regular_count))
  printf "🧩 摘要\n"
  printf "总更新：%s\t|\t🔒 安全：%s\t|\t⚙️ 常规：%s\n\n" "$total" "$security_count" "$regular_count"
  printf "🔒 安全更新 (%s)\n" "$security_count"
  [[ $security_count -gt 0 ]] && echo "$security_list" | format_inst_lines
  printf "\n⚙️ 常规更新 (%s)\n" "$regular_count"
  [[ $regular_count -gt 0 ]] && echo "$regular_list" | format_inst_lines
  printf "\n🕒 检测时间\n%s\n\n" "$(date +'%Y-%m-%d %H:%M:%S')"
  printf "🌐 DebNAS 项目主页\nhttps://github.com/kekylin/debnas\n\n"
  printf "此邮件为系统自动发送，请勿直接回复。\n"
}

send_mail(){
  local to subject
  to=$(get_email)
  subject="更新通知 — 发现 $((security_count + regular_count)) 个可用更新"
  log_action "正在发送通知邮件到 ${to}"
  {
    echo "Subject: ${subject}"
    echo "To: ${to}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    build_report
  } | /usr/sbin/exim4 -t
}

run_check
if [[ $((security_count + regular_count)) -gt 0 ]]; then
  send_mail
  log_success "检测到更新，已发送通知邮件"
fi
EOF
  chmod +x "$script_path"
  echo "$script_path"
  return 0
}

# 验证 cron 表达式，防止无效定时任务

validate_cron_expression() {
  local cron="$1"
  # 使用空格拆分，避免全局 IFS 导致无法按空格分隔
  local fields=()
  local __old_ifs="$IFS"
  IFS=' ' read -r -a fields <<< "$cron"
  IFS="$__old_ifs"
  if [[ ${#fields[@]} -ne 5 ]]; then
    log_error "Cron 表达式必须包含 5 个字段（分钟 小时 日 月 星期）。"
    return 1
  fi
  local ranges=("0-59" "0-23" "1-31" "1-12" "0-7")
  local i
  for i in {0..4}; do
    local value="${fields[$i]}" range="${ranges[$i]}"
    local min=${range%-*} max=${range#*-}
    if [[ "$value" =~ ^[0-9*]+(-[0-9]+)?(/[0-9]+)?$ || "$value" =~ ^[0-9]+(,[0-9]+)*$ || "$value" == "*" ]]; then
      if [[ "$value" != "*" ]]; then
        # 支持 */step 语法（如 */2）
        if [[ "$value" =~ ^\*/([0-9]+)$ ]]; then
          local step=${BASH_REMATCH[1]}
          if [[ "$step" -eq 0 ]]; then
            log_error "步长字段 $value 无效。"
            return 1
          fi
          continue
        fi
        if [[ "$value" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          local start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
          if [[ "$start" -lt "$min" ]] || [[ "$end" -gt "$max" ]] || [[ "$start" -gt "$end" ]]; then
            log_error "字段 ${value} 超出范围 ${range}。"
            return 1
          fi
        elif [[ "$value" =~ ^([0-9]+)/([0-9]+)$ ]]; then
          local start=${BASH_REMATCH[1]} step=${BASH_REMATCH[2]}
          if [[ "$start" -lt "$min" ]] || [[ "$start" -gt "$max" ]] || [[ "$step" -eq 0 ]]; then
            log_error "步长字段 ${value} 无效。"
            return 1
          fi
        elif [[ "$value" =~ ^([0-9]+)(,([0-9]+))*$ ]]; then
          IFS=',' read -r -a numbers <<< "$value"
          for num in "${numbers[@]}"; do
            if [[ "$num" -lt "$min" ]] || [[ "$num" -gt "$max" ]]; then
              log_error "列表值 ${num} 超出范围 ${range}。"
              return 1
            fi
          done
        elif ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt "$min" ]] || [[ "$value" -gt "$max" ]]; then
          log_error "字段 ${value} 超出范围 ${range}。"
          return 1
        fi
      fi
    else
      log_error "字段 ${value} 包含无效字符或格式。"
      return 1
    fi
  done
  return 0
}

# 将 Inst 行格式化为“包名  旧版 → 新版”

set_cron_task() {
  local schedule="$1" cron
  [[ "$schedule" == "daily" ]] && cron="0 0 * * *" || cron="0 0 * * 1"

  # 清理旧版 cron.d 文件（兼容迁移）
  rm -f "$CRON_TASK_FILE" 2>/dev/null || true

  if cron_register "check-system-updates" "$cron" 2>/dev/null; then
    [[ "$schedule" == "daily" ]] && log_success "已设置每日检测任务" || log_success "已设置每周检测任务"
  else
    log_error "设置定时任务失败"
    return 1
  fi
}

# 配置自定义 cron 定时任务（使用统一 cron 框架）
set_custom_cron_task() {
  local cron
  read -p "请输入 cron 表达式（示例：0 0 * * * 表示每日00:00）： " cron
  validate_cron_expression "$cron" || return 1

  # 清理旧版 cron.d 文件（兼容迁移）
  rm -f "$CRON_TASK_FILE" 2>/dev/null || true

  if cron_register "check-system-updates" "$cron" 2>/dev/null; then
    log_success "已设置自定义检测任务（${cron}）"
  else
    log_error "设置定时任务失败"
    return 1
  fi
}

# 列出当前 cron 定时任务
list_cron_tasks() {
  if [[ -f "$CRON_TASK_FILE" ]]; then
    log_info "当前定时任务：$(cat "$CRON_TASK_FILE")"
  else
    log_info "无定时任务"
  fi
  sleep 2
}

# 移除 cron 定时任务
remove_cron_task() {
  USER_HOME=$(eval echo ~$USER)
  rm -f "$CRON_TASK_FILE" 2>/dev/null
  rm -f "$USER_HOME/.system-update-checker.sh" 2>/dev/null
  systemctl restart cron
  log_success "已移除定时任务并删除关联脚本 ${USER_HOME}/.system-update-checker.sh"
  sleep 1
}

# 显示主菜单并处理用户选择
