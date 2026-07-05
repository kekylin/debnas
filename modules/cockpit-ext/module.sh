#!/bin/bash
# @module: cockpit-ext
# @name: 外网访问
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

main() {
  source "${SCRIPT_DIR}/lib/system/state.sh"
  source "${MODULE_DIR}/actions.sh"

  run_submenu "外网访问" \
    "enable_cockpit_ext" "启用外网访问" \
    "disable_cockpit_ext" "禁用外网访问"
}

main "$@"
