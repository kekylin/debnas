#!/bin/bash
# @module: login-mail
# @name: 登录邮件通知
# @category: 通知服务
# @depends: exim4
# @depend_modules: mail-account
# @version: 1.0.0
# @order: 61
# @interactive: true
# 功能：配置用户登录邮件通知（启用/禁用）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

main() {
  source "${SCRIPT_DIR}/lib/system/state.sh"
  source "${MODULE_DIR}/actions.sh"

  local -a items=("启用登录邮件通知" "禁用登录邮件通知")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "登录邮件通知" "${items[@]}" || {
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
      0) enable_login_mail ;;
      1) disable_login_mail ;;
    esac
  done
}

main "$@"
