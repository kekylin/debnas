#!/bin/bash
# @module: homenas-secure
# @name: 一键部署安全环境
# @category: 一键部署
# @depend_modules: sources,basic-tools,cockpit,security
# @version: 1.0.0
# @order: 81
# 功能：一键配置 HomeNAS 安全版（批量自动化执行基础+安全+邮件等模块）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap-core.sh"

# 依次批量执行安全版所需模块，提升初始化与安全防护效率
MODULES=(
  "sources|配置软件源"
  "basic-tools|安装必备软件"
  "cockpit|安装 Cockpit 面板"
  "cockpit-net|设置 Cockpit 网络访问"
  "mail-account|设置发送邮件账户"
  "login-mail-on|启用登录邮件通知"
  "security|配置基础安全防护"
  "firewall|安装防火墙服务"
  "fail2ban|安装 fail2ban 自动封锁"
  "docker-ce|安装 Docker"
  "docker-mirror|添加 Docker 镜像加速"
  "service-query|安装服务查询工具"
)

for mod_desc in "${MODULES[@]}"; do
  script_name="${mod_desc%%|*}"
  zh_desc="${mod_desc#*|}"
  log_action "正在执行模块：${zh_desc}..."
  if ! bash "${SCRIPT_DIR}/modules/${script_name}.sh"; then
    log_fail "模块 ${zh_desc} 执行失败，已中断一键配置。"
    exit "${ERROR_GENERAL}"
  fi
done
