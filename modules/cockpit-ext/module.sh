#!/bin/bash
# @module: cockpit-ext
# @name: Cockpit 外网访问
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 32
# @interactive: true
# 功能：配置 Cockpit 外网访问（启用/禁用）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

_COCKPIT_EXT_CONF="/etc/cockpit/cockpit.conf"

# 读取未注释的 Origins 值（无则空）；返回 2 表示无权读取
_cockpit_ext_origins() {
  [[ -e "$_COCKPIT_EXT_CONF" ]] || return 0
  [[ -r "$_COCKPIT_EXT_CONF" ]] || return 2
  sed -nE '/^[[:space:]]*Origins[[:space:]]*=/{s/^[[:space:]]*Origins[[:space:]]*=[[:space:]]*//p;q;}' "$_COCKPIT_EXT_CONF" 2>/dev/null || true
}

_cockpit_ext_installed() {
  pkg_is_installed cockpit-ws || pkg_is_installed cockpit
}

# 当前状态：一行 "状态码|说明"
module_status() {
  if ! _cockpit_ext_installed; then
    echo "absent|未安装 Cockpit"
    return 0
  fi
  local origins="" rc=0 hosts=""
  origins=$(_cockpit_ext_origins) || rc=$?
  if [[ $rc -eq 2 ]]; then
    echo "unknown|${_COCKPIT_EXT_CONF} 需 root 查看"
    return 0
  fi
  if [[ -z "$origins" ]]; then
    echo "absent|未配置外网访问（无 Origins）"
    return 0
  fi
  # 只展示 https:// 来源的主机部分
  local o
  local IFS=$' \t'
  for o in $origins; do
    [[ "$o" == https://* ]] && hosts+="${hosts:+, }${o#https://}"
  done
  if ! service_is_active cockpit.socket && ! service_is_active cockpit; then
    echo "warn|已配置 Origins（${hosts:-$origins}），但 Cockpit 未运行"
  else
    echo "applied|外网访问已配置：${hosts:-$origins}"
  fi
}

# 预演：每行 "类型|目标|备注"（交互式模块：列出各菜单动作可能的影响）
module_plan() {
  local IFS=$' \n\t'
  local origins="" rc=0
  echo "info|cockpit-ext|交互式菜单：启用（输入外网域名[:端口]）/ 禁用，按选择执行"
  if ! _cockpit_ext_installed; then
    echo "risk|cockpit|未安装 Cockpit，请先执行 cockpit 模块"
  fi
  origins=$(_cockpit_ext_origins) || rc=$?
  if [[ $rc -eq 2 ]]; then
    echo "info|${_COCKPIT_EXT_CONF}|当前配置需 root 查看"
  elif [[ -n "$origins" ]]; then
    echo "info|当前 Origins|${origins}"
  else
    echo "info|当前 Origins|未配置"
  fi
  echo "write|${_COCKPIT_EXT_CONF}|启用：设置 [WebService] Origins = https://<域名> wss://<域名> https://<内网IP>:9090；禁用：删除 Origins 行；内容未变则跳过，旧文件备份到 /var/backups/debnas/"
  echo "service|cockpit|配置变更后重启（当前 Cockpit 会话会断开）"
  echo "risk|外网暴露|Origins 只校验跨域来源、不是访问控制；对公网开放 Cockpit 登录页前建议启用 fail2ban 并限制来源"
  return 0
}

main() {
  source "${MODULE_DIR}/actions.sh"

  local -a items=("启用外网访问" "禁用外网访问")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "Cockpit 外网访问" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   continue ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"
    case "$choice" in
      0) enable_cockpit_ext || true ;;    # 失败只提示，不让 set -e 退出菜单
      1) disable_cockpit_ext || true ;;
    esac
  done
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
