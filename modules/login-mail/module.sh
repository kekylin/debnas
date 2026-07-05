#!/bin/bash
# @module: login-mail
# @name: 登录通知
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

  run_submenu "登录通知" \
    "enable_login_mail" "启用登录通知" \
    "disable_login_mail" "禁用登录通知"
}

main "$@"
