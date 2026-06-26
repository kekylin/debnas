#!/bin/bash
# check-system-updates: 邮件通知逻辑
set -euo pipefail
IFS=$'\n\t'
get_hostname() {
  local hostname=$(hostname 2>/dev/null)
  if [[ -z "$hostname" || "$hostname" == "(none)" ]]; then
    get_system_name
  else
    echo "$hostname"
  fi
}

# 验证并获取邮箱配置
get_email_config() {
  if [[ ! -f "$EMAIL_CONFIG_FILE" ]] || [[ -z "$(cat "$EMAIL_CONFIG_FILE")" ]]; then
    log_error "未找到有效的邮箱配置，文件 ${EMAIL_CONFIG_FILE} 不存在或为空。"
    exit "${ERROR_CONFIG}"
  fi
  echo "$(cat "$EMAIL_CONFIG_FILE")"
}

# 设置脚本文件并赋予权限

format_inst_lines() {
  # 从 stdin 读取 Inst 行，双遍扫描对齐列宽
  awk '
  /^Inst / {
    if (match($0, /^Inst[[:space:]]+([^[:space:]]+)[[:space:]]+\[([^\]]+)\][[:space:]]+\(([^[:space:]]+)/, m)) {
      n++; pkg[n]=m[1]; oldv[n]=m[2]; newv[n]=m[3];
    }
    next
  }
  END {
    for (i=1;i<=n;i++) {
      printf "%s\n   ↳ %s → %s\n\n", pkg[i], oldv[i], newv[i];
    }
  }'
}

# 检测系统版本更新

build_report_content() {
  local security_update_list="$1" security_update_count="$2" regular_update_list="$3" regular_update_count="$4"
  local total=$((security_update_count + regular_update_count))
  printf "🧩 摘要\n"
  printf "总更新：%s\t|\t🔒 安全：%s\t|\t⚙️ 常规：%s\n\n" "${total}" "${security_update_count}" "${regular_update_count}"

  printf "🔒 安全更新 (%s)\n" "${security_update_count}"
  if [[ ${security_update_count} -gt 0 ]]; then
    echo -e "${security_update_list}" | format_inst_lines
  fi
  printf "\n⚙️ 常规更新 (%s)\n" "${regular_update_count}"
  if [[ ${regular_update_count} -gt 0 ]]; then
    echo -e "${regular_update_list}" | format_inst_lines
  fi
  printf "\n🕒 检测时间\n"
  printf "%s\n\n" "$(date +'%Y-%m-%d %H:%M:%S')"
  printf "🌐 DebNAS 项目主页\n"
  printf "https://github.com/kekylin/debnas\n\n"
  printf "此邮件由系统自动生成，请勿直接回复。\n"
}

# 执行更新检测并生成报告
run_update_check() {
  log_action "正在生成系统更新报告"
  # 刷新索引；若失败则记录警告但不中止
  apt-get update > /dev/null 2>&1 || log_warning "apt-get update 执行失败，已跳过索引刷新。"
  full_update_list=$(apt-get upgrade -s)
  
  declare -g security_update_list=$(echo "$full_update_list" | grep -E '^Inst' | grep -i 'Debian-Security\|security')
  declare -g security_update_count=$(echo "$security_update_list" | grep -c "^Inst")
  
  declare -g regular_update_list=$(echo "$full_update_list" | grep -E '^Inst' | grep -vi 'Debian-Security\|security')
  declare -g regular_update_count=$(echo "$regular_update_list" | grep -c "^Inst")
  
  declare -g report_content=$(build_report_content "$security_update_list" "$security_update_count" "$regular_update_list" "$regular_update_count")
}

# 发送邮件通知
send_email_notification() {
  local notify_email=$(get_email_config)
  local hostname=$(get_hostname)
  local total_count=$((security_update_count + regular_update_count))
  local subject="更新通知 — 发现 ${total_count} 个可用更新"
  
  log_action "正在发送通知邮件到 ${notify_email}"
  {
    echo "Subject: ${subject}"
    echo "To: ${notify_email}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo -e "$report_content"
  } | /usr/sbin/exim4 -t
}

# 执行更新检测并处理结果
