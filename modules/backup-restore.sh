#!/bin/bash
# @module: backup-restore
# @name: 备份恢复
# @category: 容器管理
# @depends: docker,tar,rsync
# @depend_modules: install-docker-ce
# @version: 2.0.0
# @order: 53
# 功能：Docker 容器与数据卷的备份与恢复（兼容层）
set -euo pipefail
IFS=$'\n\t'
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-restore/module.sh" "$@"
