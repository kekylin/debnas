#!/bin/bash
# @module: cockpit-auto-bing-wallpaper
# @name: 面板必应壁纸
# @category: 管理面板
# @depends: wget,systemctl,crontab
# @depend_modules: install-cockpit
# @version: 1.0.0
# @order: 35
# @cron: true
# @cron_schedule: 0 */6 * * *
# 功能：Cockpit 登录页必应每日壁纸自动管理（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

source "${MODULE_DIR}/download.sh"
source "${MODULE_DIR}/configure.sh"
source "${MODULE_DIR}/cron.sh"

# 错误码常量
ERROR_DEPENDENCY=2

# 依赖检查
REQUIRED_CMDS=(curl crontab)
check_dependencies "${REQUIRED_CMDS[@]}" || {
  log_error "依赖缺失，请先安装必要工具。"
  exit "${ERROR_DEPENDENCY}"
}

# 常量定义
readonly BRANDING_DIR="/etc/cockpit/branding"
readonly BRANDING_CSS="${BRANDING_DIR}/branding.css"
readonly WALLPAPER_FILE="${BRANDING_DIR}/login-bg.png"
readonly ISSUE_FILE="/etc/cockpit/issue.cockpit"
readonly STATE_FILE="${BRANDING_DIR}/.initialized"
readonly SCRIPT_COPY="${BRANDING_DIR}/cockpit-bing-wallpaper.sh"
readonly BING_API_URL="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN"
readonly SELF_PATH="$(realpath "$0")"

# 日志输出到终端

log_to_file() {
  local log_func="$1" message="$2"
  "$log_func" "$message"
}

# 状态检测
is_first_run() { [[ ! -f "$STATE_FILE" ]]; }
mark_initialized() { touch "$STATE_FILE"; }
is_auto_mode() { [[ ! -t 0 ]] || [[ -n "${CRON:-}" ]]; }

# Cockpit版本检查

check_cockpit_version() {
  local cockpit_version=0
  
  # 优先使用 cockpit-bridge（标准方法）
  if command -v cockpit-bridge >/dev/null 2>&1; then
    cockpit_version=$(cockpit-bridge --version 2>/dev/null | grep -oP 'Version: \K[0-9]+' | head -n1 || echo "0")
  # 备用方法：检查 cockpit-ws
  elif command -v cockpit-ws >/dev/null 2>&1; then
    cockpit_version=$(cockpit-ws --version 2>/dev/null | grep -oP 'Version: \K[0-9]+' | head -n1 || echo "0")
  # 最后尝试：检查系统包版本
  elif command -v dpkg >/dev/null 2>&1; then
    cockpit_version=$(dpkg -l | grep -oP '^ii\s+cockpit\s+\K[0-9]+' | head -n1 | cut -d. -f1 || echo "0")
  fi
  
  if [[ "$cockpit_version" -eq 0 ]]; then
    log_error "Cockpit 未安装或版本检测失败"
    return 1
  fi
  
  if [[ "$cockpit_version" -lt 347 ]]; then
    log_error "Cockpit 版本过低 (${cockpit_version})，需要 347 或更高版本"
    return 1
  fi
  
  return 0
}

# 初始化环境目录

main_menu() {
  local -a menu_options=("启用必应壁纸" "禁用必应壁纸" "查看壁纸计划")
  
  while true; do
    show_menu_with_border "Cockpit 必应壁纸" "${menu_options[@]}"
    print_prompt "请选择编号: "
    read -r choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 0 ]] || [[ "$choice" -gt "${#menu_options[@]}" ]]; then
      log_error "无效选择，请输入 0-${#menu_options[@]}"
      continue
    fi
    
    case "$choice" in
      1) enable_bing_wallpaper ;;
      2) disable_bing_wallpaper ;;
      3) show_cron_jobs ;;
      0) break ;;
    esac
    echo ""
  done
}

# 主函数
main() {
  if [[ "${1:-}" == "--auto" ]] || [[ -n "${CRON:-}" ]]; then
    auto_update_mode
  elif [[ "${1:-}" == "--interactive" ]]; then
    main_menu
  elif [[ -t 0 ]]; then
    main_menu
  else
    log_info "非交互式调用，启用必应壁纸"
    enable_bing_wallpaper
  fi
}

# 程序入口点
