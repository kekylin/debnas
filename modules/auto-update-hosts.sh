#!/bin/bash
# 功能：自动更新 /etc/hosts 文件

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查依赖，确保 curl、cp、awk 已安装
REQUIRED_CMDS=(curl cp awk)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 curl、cp、awk。"
  exit "${ERROR_DEPENDENCY}"
fi

# hosts 文件路径及标记，便于后续自动识别和更新
HOSTS_FILE="/etc/hosts"
START_MARK="# Kekylin Hosts Start"
END_MARK="# Kekylin Hosts End"
NEW_HOSTS=""
DOWNLOAD_URLS=(
  "https://ghfast.top/https://raw.githubusercontent.com/kekylin/hosts/main/hosts"
  "https://raw.githubusercontent.com/kekylin/hosts/main/hosts"
)

# 检查可用的下载工具，优先使用 curl
check_download_tool() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_TOOL="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_TOOL="wget"
  else
    log_error "未找到 curl 或 wget，请先安装其中之一。"
    exit "${ERROR_DEPENDENCY}"
  fi
}

# 下载 hosts 文件，支持 curl 和 wget
download_hosts() {
  local url="$1"
  if [ "$DOWNLOAD_TOOL" = "curl" ]; then
    curl -s -k -L --max-time 15 "$url"
    return $?
  else
    wget -q -O - --timeout=15 "$url" 2>/dev/null
    return $?
  fi
}

# 更新 hosts 文件，自动处理标记区间
update_hosts() {
  local url
  NEW_HOSTS=""
  check_download_tool
  for url in "${DOWNLOAD_URLS[@]}"; do
    log_action "尝试从 $url 下载 hosts 文件..."
    NEW_HOSTS=$(download_hosts "$url")
    if [ $? -eq 0 ] && [ -n "$NEW_HOSTS" ]; then
      log_success "已成功从 $url 下载 hosts 文件。"
      break
    else
      log_fail "从 $url 下载失败，尝试下一个地址..."
      NEW_HOSTS=""
    fi
  done
  if [ -z "$NEW_HOSTS" ]; then
    log_fail "所有下载地址均失败，未更新 hosts 文件。"
    return 1
  fi
  if grep -q "$START_MARK" $HOSTS_FILE && grep -q "$END_MARK" $HOSTS_FILE; then
    sed -i "/$START_MARK/,/$END_MARK/d" $HOSTS_FILE
  fi
  if [ -z "$(tail -n 1 $HOSTS_FILE)" ]; then
    echo -e "$NEW_HOSTS" | tee -a $HOSTS_FILE > /dev/null
  else
    echo -e "\n$NEW_HOSTS" | tee -a $HOSTS_FILE > /dev/null
  fi
}

# 创建定时任务，自动定期更新 hosts
create_cron_job() {
  if [[ -n "${USER:-}" ]]; then
    USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
  else
    USER_HOME="$HOME"
  fi
  SCRIPT_PATH="$USER_HOME/.kekylin_hosts_update.sh"
  if crontab -l | grep -q "# Kekylin Hosts Update"; then
    log_action "定时任务已存在，正在删除旧任务..."
    crontab -l | grep -v "# Kekylin Hosts Update" | crontab -
  fi
  if ! update_hosts; then
    log_fail "取消创建定时任务。"
    return 1
  fi
  cp "$0" "$SCRIPT_PATH"
  cron_job="0 0,6,12,18 * * * /bin/bash $SCRIPT_PATH update_hosts # Kekylin Hosts Update"
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
  log_success "定时任务已创建，每天0点、6点、12点和18点自动执行。"
  log_success "hosts 自动更新相关配置已全部完成。"
}

# 查询定时任务，便于用户确认当前计划
list_cron_jobs() {
  log_info "定时任务如下："
  crontab -l || log_info "当前没有定时任务。"
}

# 菜单函数，供用户选择操作
menu() {
  local menu_options=(
    "单次更新"
    "定时更新"
    "删除定时任务"
    "查询定时任务"
  )
  print_separator "-"
  print_menu_item "1" "单次更新"
  print_menu_item "2" "定时更新"
  print_menu_item "3" "删除定时任务"
  print_menu_item "4" "查询定时任务"
  print_menu_item "0" "返回" "true"
  print_separator "-"
  print_prompt "请选择编号: "
  read -r choice
  case $choice in
    1)
      log_action "单次更新"
      update_hosts
      ;;
    2)
      log_action "定时更新"
      create_cron_job
      ;;
    3)
      crontab -l | grep -v "# Kekylin Hosts Update" | crontab -
      log_success "定时任务已删除。"
      ;;
    4)
      list_cron_jobs
      ;;
    0)
      return 0
      ;;
  esac
}

# 主执行流程，支持定时任务和交互菜单
main() {
  if [[ "${1:-}" == "update_hosts" ]]; then
    update_hosts
  else
    menu
  fi
}

main "$@"
