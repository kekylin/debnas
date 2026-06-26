#!/bin/bash
# check-system-updates: 更新检查逻辑
set -euo pipefail
IFS=$'\n\t'
detect_major_version_update() {
  local system_name=$(get_system_name)
  local current_version
  
  if [[ "$system_name" == "Debian" ]]; then
    if [[ -f /etc/debian_version ]]; then
      current_version=$(cat /etc/debian_version)
    else
      current_version=$(grep -oP '^VERSION_ID="\K[0-9.]+' /etc/os-release || echo "未知")
    fi
  else  # Ubuntu
    if command -v lsb_release >/dev/null 2>&1; then
      current_version=$(lsb_release -rs)
    else
      current_version=$(grep -oP '^VERSION_ID="\K[0-9.]+' /etc/os-release || echo "未知")
    fi
  fi
  
  local release_info=$(apt-get -s dist-upgrade | grep -i "inst.*${system_name}.*release" -i)
    if [[ -n "$release_info" ]]; then
      local new_version=$(echo "$release_info" | awk '{print $2}' | grep -o '[0-9]\+\.[0-9]\+')
      if [[ -n "$new_version" && "$new_version" != "$current_version" ]]; then
      echo -e "${system_name}: ${current_version} → ${new_version}"
    fi
  fi
}

# 生成报告内容
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

execute_update_check() {
  if ! verify_system_support; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi
  run_update_check
  if [[ $security_update_count -gt 0 || $regular_update_count -gt 0 ]]; then
    send_email_notification
    log_success "检测到更新，已发送通知邮件"
  else
    log_info "系统已是最新状态，无可用更新"
  fi
  sleep 2
}

# 配置 cron 定时任务（使用统一 cron 框架）
