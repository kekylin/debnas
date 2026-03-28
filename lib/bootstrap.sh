#!/bin/bash
# 功能：DebNAS 公共模块加载入口，统一 set/IFS/常用库加载

set -euo pipefail
IFS=$'\n\t'

# 获取脚本根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载核心常量、日志、依赖、工具库
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/urls.sh"

# 可选加载 UI 组件
if [[ -f "${SCRIPT_DIR}/lib/ui/menu.sh" ]]; then
  source "${SCRIPT_DIR}/lib/ui/menu.sh"
fi
if [[ -f "${SCRIPT_DIR}/lib/ui/styles.sh" ]]; then
  source "${SCRIPT_DIR}/lib/ui/styles.sh"
fi

# 用法：在主脚本头部 source 本文件即可自动加载所有基础依赖
