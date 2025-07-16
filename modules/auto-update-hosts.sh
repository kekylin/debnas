#!/bin/bash
# 功能：自动更新 /etc/hosts 文件
# 参数：无
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查依赖
REQUIRED_CMDS=(curl cp awk)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 curl、cp、awk"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置hosts文件路径
HOSTS_FILE="/etc/hosts"
START_MARK="# Kekylin Hosts Start"
END_MARK="# Kekylin Hosts End"
NEW_HOSTS=""
DOWNLOAD_URLS=(
  "https://ghfast.top/https://raw.githubusercontent.com/kekylin/hosts/main/hosts"  # 主用地址
  "https://raw.githubusercontent.com/kekylin/hosts/main/hosts"  # 备用地址
)

# 检查下载工具
check_download_tool() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_TOOL="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_TOOL="wget"
  else
    log_error "未找到curl或wget，请先安装其中之一"
    exit "${ERROR_DEPENDENCY}"
  fi
}

# 下载函数
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

# 更新hosts文件
update_hosts() {
  local url
  NEW_HOSTS=""

  # 检查下载工具
  check_download_tool

  # 尝试多个下载地址
  for url in "${DOWNLOAD_URLS[@]}"; do
    log_action "尝试从 $url 下载 Hosts 文件..."
    
    NEW_HOSTS=$(download_hosts "$url")
    
    # 检查是否下载成功
    if [ $? -eq 0 ] && [ -n "$NEW_HOSTS" ]; then
      log_success "成功从 $url 下载 Hosts 文件"
      break
    else
      log_fail "从 $url 下载失败，尝试下一个地址..."
      NEW_HOSTS=""
    fi
  done

  # 如果没有成功下载内容，则退出，避免后续动作
  if [ -z "$NEW_HOSTS" ]; then
    log_fail "所有下载地址均失败，未更新 Hosts 文件"
    return 1  # 返回1表示失败，停止后续操作
  fi

  # 如果 hosts 文件中存在标记，则删除标记间内容
  if grep -q "$START_MARK" $HOSTS_FILE && grep -q "$END_MARK" $HOSTS_FILE; then
    sed -i "/$START_MARK/,/$END_MARK/d" $HOSTS_FILE
  fi

  # 更新文件内容
  if [ -z "$(tail -n 1 $HOSTS_FILE)" ]; then
    echo -e "$NEW_HOSTS" | tee -a $HOSTS_FILE > /dev/null
  else
    echo -e "\n$NEW_HOSTS" | tee -a $HOSTS_FILE > /dev/null
  fi

}

# 创建定时任务
create_cron_job() {
  # 安全地获取用户主目录，避免命令注入
  if [[ -n "${USER:-}" ]]; then
    USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
  else
    USER_HOME="$HOME"
  fi
  SCRIPT_PATH="$USER_HOME/.kekylin_hosts_update.sh"

  # 删除旧任务（如果存在）
  if crontab -l | grep -q "# Kekylin Hosts Update"; then
    log_action "定时任务已存在，正在删除旧任务..."
    crontab -l | grep -v "# Kekylin Hosts Update" | crontab -
  fi

  # 只有当下载成功时才进行后续操作
  if ! update_hosts; then
    log_fail "取消创建定时任务"
    return 1
  fi

  # 复制脚本到用户目录并创建新任务
  cp "$0" "$SCRIPT_PATH"
  cron_job="0 0,6,12,18 * * * /bin/bash $SCRIPT_PATH update_hosts # Kekylin Hosts Update"
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
  log_success "定时任务已创建，每天0点、6点、12点和18点自动执行"

  log_success "Hosts自动更新相关配置已全部完成。"
}

# 查询定时任务
list_cron_jobs() {
  log_info "定时任务如下："
  crontab -l || log_info "当前没有定时任务"
}

# 菜单函数
menu() {
  local menu_options=(
    "单次更新Hosts文件"
    "定时更新Hosts文件"
    "删除定时更新任务"
    "查询定时任务"
  )
  
  show_menu_with_border "请选择操作" "${menu_options[@]}"
  choice=$(get_user_choice ${#menu_options[@]})
  
  case $choice in
    1)
      log_action "您选择了单次更新Hosts文件"
      update_hosts
      ;;
    2)
      log_action "您选择了定时更新Hosts文件"
      create_cron_job
      ;;
    3)
      crontab -l | grep -v "# Kekylin Hosts Update" | crontab -
      log_success "定时任务已删除"
      ;;
    4)
      list_cron_jobs
      ;;
    0)
      return 0
      ;;
  esac
}

# 主执行流程
main() {
  # 如果是定时任务触发，直接更新hosts
  if [[ "$1" == "update_hosts" ]]; then
    update_hosts
  else
    menu
  fi
}

# 执行主函数
main "$@"
