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
# 功能：Cockpit 必应壁纸（兼容层）
set -euo pipefail
IFS=$'\n\t'
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cockpit-auto-bing-wallpaper/module.sh" "$@"
