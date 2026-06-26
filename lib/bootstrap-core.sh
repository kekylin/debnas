#!/bin/bash
# bootstrap-core.sh — 轻量级库加载入口
# 仅加载核心 + 基础系统库，适合模块使用
# 完整加载请使用 bootstrap.sh

set -euo pipefail
IFS=$'\n\t'

# 防止重复加载
if [[ "${_DEBNAS_CORE_LOADED:-0}" -eq 1 ]]; then
  return 0 2>/dev/null || true
fi

_DEBNAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ==================== Core layer（零依赖） ====================
source "${_DEBNAS_ROOT}/lib/core/constants.sh"
source "${_DEBNAS_ROOT}/lib/core/colors.sh"
source "${_DEBNAS_ROOT}/lib/core/logging.sh"

# ==================== 基础 System layer ====================
source "${_DEBNAS_ROOT}/lib/system/utils.sh"
source "${_DEBNAS_ROOT}/lib/system/dependency.sh"
source "${_DEBNAS_ROOT}/lib/system/tempfile.sh"
source "${_DEBNAS_ROOT}/lib/system/urls.sh"
source "${_DEBNAS_ROOT}/lib/system/apt-pinning.sh"
source "${_DEBNAS_ROOT}/lib/system/apt.sh"
source "${_DEBNAS_ROOT}/lib/system/service.sh"

# ==================== 自动注册临时文件清理 ====================
register_temp_cleanup

_DEBNAS_CORE_LOADED=1
