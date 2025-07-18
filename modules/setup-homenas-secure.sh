#!/bin/bash
# 功能：一键配置 HomeNAS 安全版（批量自动化执行基础+安全+邮件等模块）
# 参数：无
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"

# 依次批量执行安全版所需模块（模块名|中文描述）
MODULES=(
  "configure-sources|配置软件源"
  "install-basic-tools|安装必备软件"
  "install-cockpit|安装 Cockpit 面板"
  "set-cockpit-network|设置 Cockpit 网络访问"
  "setup-mail-account|设置发送邮件账户"
  "enable-login-mail|启用登录邮件通知"
  "configure-security|配置基础安全防护"
  "install-firewall|安装防火墙服务"
  "install-fail2ban|安装 fail2ban 自动封锁"
  "install-docker|安装 Docker"
  "add-docker-mirror|添加 Docker 镜像加速"
  "install-service-query|安装服务查询工具"
)

for mod_desc in "${MODULES[@]}"; do
  script_name="${mod_desc%%|*}"
  zh_desc="${mod_desc#*|}"
  log_action "正在执行模块：\"${zh_desc}\" ..."
  bash "${SCRIPT_DIR}/modules/${script_name}.sh"
  if [[ $? -ne 0 ]]; then
    log_fail "模块 \"${zh_desc}\" 执行失败"
    exit "${ERROR_GENERAL}"
  fi
done

log_success "一键安全环境配置已全部完成。"
