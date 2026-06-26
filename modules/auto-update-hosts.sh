#!/bin/bash
# @module: auto-update-hosts
# @name: 更新 Hosts 文件
# @category: 系统工具
# @depends: dig,ping
# @depend_modules: configure-sources
# @version: 2.0.0
# @order: 73
# @cron: true
# @cron_schedule: 0 3 * * *
# 功能：自动更新 /etc/hosts 文件（兼容层，转发到目录模块）

set -euo pipefail
IFS=$'\n\t'

exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/auto-update-hosts/module.sh" "$@"
