#!/bin/bash
# @module: block-threat-ips
# @name: IP 封禁工具
# @category: 安全防护
# @depends: firewall-cmd,ipset,wget,gzip,awk,sed,grep,sort,comm,head,crontab,sipcalc
# @depend_modules: install-firewall
# @version: 2.0.0
# @order: 43
# @cron: true
# @cron_schedule: 0 */6 * * *
# 功能：Firewalld-IPThreat 自动化威胁情报更新系统（兼容层，转发到目录模块）
#
# 此文件保留向后兼容性。实际功能已迁移到 modules/block-threat-ips/ 目录。

set -euo pipefail
IFS=$'\n\t'

# 转发到目录模块入口
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-threat-ips/module.sh" "$@"
