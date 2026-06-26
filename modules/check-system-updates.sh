#!/bin/bash
# @module: check-system-updates
# @name: 检查系统更新
# @category: 系统工具
# @depends: apt
# @depend_modules: configure-sources
# @version: 1.0.0
# @order: 71
# @cron: true
# @cron_schedule: 0 6 * * *
# 功能：系统更新检查与邮件通知（兼容层）
set -euo pipefail
IFS=$'\n\t'
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-system-updates/module.sh" "$@"
