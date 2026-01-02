#!/bin/bash
# 功能：一键配置 HomeNAS 基础版（批量自动化执行常用初始化模块）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"

# 依次批量执行基础版所需模块，提升初始化效率
MODULES=(
  "configure-sources|配置软件源"
  "install-basic-tools|安装必备软件"
  "install-cockpit|安装 Cockpit 面板"
  "set-cockpit-network|设置 Cockpit 网络访问"
  "install-docker-ce|安装 Docker"
  "add-docker-mirror|添加 Docker 镜像加速"
  "install-service-query|安装服务查询工具"
)

for mod_desc in "${MODULES[@]}"; do
  script_name="${mod_desc%%|*}"
  zh_desc="${mod_desc#*|}"
  log_action "正在执行模块：${zh_desc}..."
  if [[ "$script_name" == "configure-sources" ]]; then
    bash "$SCRIPT_DIR/modules/${script_name}.sh" --auto
  else
    bash "$SCRIPT_DIR/modules/${script_name}.sh"
  fi
  if [[ $? -ne 0 ]]; then
    log_fail "模块 ${zh_desc} 执行失败，已中断一键配置。"
    exit "${ERROR_GENERAL}"
  fi
done
