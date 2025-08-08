#!/bin/bash
# 功能：系统更新检查与邮件通知（支持定时任务管理）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查依赖，确保必备命令已安装
REQUIRED_CMDS=(apt grep awk mail systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 定义文件路径常量
EMAIL_CONFIG_FILE="/etc/exim4/notify_email"
CRON_TASK_FILE="/etc/cron.d/system-update-checker"

# 验证并获取邮箱配置
get_email_config() {
  if [[ ! -f "$EMAIL_CONFIG_FILE" ]] || [[ -z "$(cat "$EMAIL_CONFIG_FILE")" ]]; then
    log_error "未找到有效的邮箱配置，文件 ${EMAIL_CONFIG_FILE} 不存在或为空。"
    exit "${ERROR_CONFIG}"
  fi
  echo "$(cat "$EMAIL_CONFIG_FILE")"
}

# 设置脚本文件并赋予权限
setup_script_file() {
  local current_script=$(readlink -f "$0")
  USER_HOME=$(eval echo ~$USER)
  local script_path="$USER_HOME/.system-update-checker.sh"
  if [[ "$current_script" != "$script_path" ]]; then
    cp "$current_script" "$script_path" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      log_error "无法复制脚本到 ${script_path}，请检查权限。"
      return 1
    fi
    chmod +x "$script_path" 2>/dev/null
  fi
  if [[ ! -f "$script_path" ]]; then
    log_error "脚本文件 ${script_path} 不存在，请确保脚本已正确复制。"
    return 1
  fi
  echo "$script_path"
  return 0
}

# 验证 cron 表达式，防止无效定时任务
validate_cron_expression() {
  local cron="$1"
  local fields=($cron)
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

# 格式化更新列表
format_update_list() {
  local updates="$1" count="$2" title="$3"
  [[ $count -gt 0 ]] && printf "%s\n%s\n" "${title}（${count}个）：" "$(echo -e "$updates" | awk '/^Inst/ {printf "  %s: [%s] (%s)\n", $2, $3, $4}')"
}

# 检测系统版本更新
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
  local major_update_info=$(detect_major_version_update)
  printf "更新摘要：\n"
  printf "总可用更新: %s 个 | 安全更新: %s 个 | 常规更新: %s 个\n\n" "${total}" "${security_update_count}" "${regular_update_count}"
  printf "更新详情：\n"
  [[ -n "$major_update_info" ]] && printf "系统版本更新:\n%s\n" "${major_update_info}"
  format_update_list "$security_update_list" "$security_update_count" "安全更新"
  [[ -n "$major_update_info" || $security_update_count -gt 0 ]] && printf "\n"
  format_update_list "$regular_update_list" "$regular_update_count" "常规更新"
  printf "\n检测时间: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')"
  printf "\n如需了解更多 DebNAS 使用方法，请访问 https://github.com/kekylin/debnas\n\n此邮件为系统自动发送，请勿直接回复。\n"
}

# 执行更新检测并生成报告
run_update_check() {
  log_action "正在生成系统更新报告"
  apt-get update > /dev/null 2>&1
  full_update_list=$(apt-get upgrade -s)
  
  declare -g security_update_list=$(echo "$full_update_list" | grep -i security | grep '^Inst')
  declare -g security_update_count=$(echo "$security_update_list" | grep -c "^Inst")
  
  declare -g regular_update_list=$(echo "$full_update_list" | grep -v -i security | grep '^Inst')
  declare -g regular_update_count=$(echo "$regular_update_list" | grep -c "^Inst")
  
  declare -g report_content=$(build_report_content "$security_update_list" "$security_update_count" "$regular_update_list" "$regular_update_count")
}

# 发送邮件通知
send_email_notification() {
  local notify_email=$(get_email_config)
  local hostname=$(get_hostname)
  local major_update_info=$(detect_major_version_update)
  local update_types=()
  
  # 确定更新类型
  [[ -n "$major_update_info" ]] && update_types+=("'系统'")
  [[ $security_update_count -gt 0 ]] && update_types+=("'安全'")
  [[ $regular_update_count -gt 0 ]] && update_types+=("'常规'")
  
  # 生成动态主题
  local subject=""
  case "${#update_types[@]}" in
    1)
      subject="发现${update_types[0]}更新"
      ;;
    2)
      subject="发现${update_types[0]}和${update_types[1]}更新"
      ;;
    3)
      subject="发现${update_types[0]}、${update_types[1]}和${update_types[2]}更新"
      ;;
    *)
      subject="发现更新"
      ;;
  esac
  
  log_action "正在发送通知邮件到 ${notify_email}"
  echo -e "$report_content" | mail -s "[${hostname} 更新通知] ${subject}" "$notify_email"
}

# 执行更新检测并处理结果
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

# 配置 cron 定时任务
set_cron_task() {
  local schedule="$1" cron
  local script_path=$(setup_script_file) || return 1
  
  rm -f "$CRON_TASK_FILE" 2>/dev/null
  [[ "$schedule" == "daily" ]] && cron="0 0 * * *" || cron="0 0 * * 1"
  echo "$cron root $script_path --check" > "$CRON_TASK_FILE"
  chmod 644 "$CRON_TASK_FILE"
  systemctl restart cron
  [[ "$schedule" == "daily" ]] && log_success "已设置每日检测任务" || log_success "已设置每周检测任务"
  sleep 1
}

# 配置自定义 cron 定时任务
set_custom_cron_task() {
  local script_path=$(setup_script_file) || return 1
  local cron
  
  read -p "请输入 cron 表达式（示例：0 0 * * * 表示每日00:00）： " cron
  validate_cron_expression "$cron" || return 1
  
  rm -f "$CRON_TASK_FILE" 2>/dev/null
  echo "$cron root $script_path --check" > "$CRON_TASK_FILE"
  chmod 644 "$CRON_TASK_FILE"
  systemctl restart cron
  log_success "已设置自定义检测任务（${cron}）"
  sleep 1
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
main_menu() {
  if ! verify_system_support; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi
  while true; do
    print_separator "-"
    print_menu_item "1" "立即执行检测"
    print_menu_item "2" "设置定时检测"
    print_menu_item "3" "查看定时任务"
    print_menu_item "4" "移除定时任务"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r choice
    
    # 验证输入
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      log_error "请输入数字编号"
      continue
    fi
    
    if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt 4 ]]; then
      log_error "无效选择，请输入 0-4"
      continue
    fi
    
    case $choice in
      1) execute_update_check ;;
      2) schedule_menu ;;
      3) list_cron_tasks ;;
      4) remove_cron_task ;;
      0) log_action "返回"; return 0 ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

# 显示定时检测子菜单并处理用户选择
schedule_menu() {
  while true; do
    print_separator "-"
    print_menu_item "1" "每日检测（00:00）"
    print_menu_item "2" "每周检测（周一00:00）"
    print_menu_item "3" "自定义定时检测"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r subchoice
    
    # 验证输入
    if [[ ! "$subchoice" =~ ^[0-9]+$ ]]; then
      log_error "请输入数字编号"
      continue
    fi
    
    if [[ "$subchoice" -lt 0 ]] || [[ "$subchoice" -gt 3 ]]; then
      log_error "无效选择，请输入 0-3"
      continue
    fi
    
    case $subchoice in
      1) set_cron_task "daily"; return ;;
      2) set_cron_task "weekly"; return ;;
      3) set_custom_cron_task; return ;;
      0) log_action "返回"; return ;;
      *) log_error "无效的操作选项，请重新选择。" ;;
    esac
  done
}

# 主程序入口
case "${1:-}" in
  "--check")
    # 仅检测，无交互，适合定时任务
    if ! verify_system_support; then
      exit "${ERROR_UNSUPPORTED_OS}"
    fi
    run_update_check
    if [[ $security_update_count -gt 0 || $regular_update_count -gt 0 ]]; then
      send_email_notification
    fi
    ;;
  *)
    # 默认进入交互菜单，适合主菜单调用和手动操作
    main_menu
    ;;
esac 
