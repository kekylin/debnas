#!/bin/bash
# bootstrap.sh — DebNAS 统一库加载入口
# 所有模块只需 source 这一行，即可加载全部基础依赖
#
# 加载顺序：
#   1. 早期标志解析（--cron 影响 UI 是否加载）
#   2. Core layer（零依赖：常量、颜色、日志）
#   3. System layer（工具库、依赖管理、APT、配置、状态等）
#   4. UI layer（cron 模式下跳过，避免颜色输出到日志）
#   5. Module Registry（模块发现与依赖解析）
#   6. 自动注册临时文件清理 trap

set -euo pipefail
IFS=$'\n\t'

# 防止重复加载
if [[ "${_DEBNAS_BOOTSTRAPPED:-0}" -eq 1 ]]; then
  return 0 2>/dev/null || true
fi

# 获取项目根目录（bootstrap.sh 位于 lib/ 下）
_DEBNAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ==================== 早期标志解析 ====================
# 在任何库加载之前解析影响加载行为的标志

_parse_early_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --cron)    export DEBNAS_CRON_MODE=1 ;;
      --debug)   export LOG_LEVEL="DEBUG" ;;
      --dry-run) export DEBNAS_DRY_RUN=1 ;;
      --yes|-y)  export DEBNAS_FORCE_YES=1 ;;
    esac
  done
}
_parse_early_flags "$@"
unset -f _parse_early_flags

# ==================== Core layer（零依赖） ====================

source "${_DEBNAS_ROOT}/lib/core/constants.sh"
source "${_DEBNAS_ROOT}/lib/core/colors.sh"
source "${_DEBNAS_ROOT}/lib/core/logging.sh"

# ==================== System layer ====================

source "${_DEBNAS_ROOT}/lib/system/utils.sh"
source "${_DEBNAS_ROOT}/lib/system/dependency.sh"
source "${_DEBNAS_ROOT}/lib/system/tempfile.sh"
source "${_DEBNAS_ROOT}/lib/system/urls.sh"
source "${_DEBNAS_ROOT}/lib/system/apt-pinning.sh"
source "${_DEBNAS_ROOT}/lib/system/apt.sh"
source "${_DEBNAS_ROOT}/lib/system/service.sh"
source "${_DEBNAS_ROOT}/lib/system/args.sh"
source "${_DEBNAS_ROOT}/lib/system/state.sh"
source "${_DEBNAS_ROOT}/lib/system/cron.sh"
source "${_DEBNAS_ROOT}/lib/system/config.sh"

# ==================== UI layer（cron 模式下跳过） ====================

if [[ "${DEBNAS_CRON_MODE:-0}" -eq 0 ]]; then
  source "${_DEBNAS_ROOT}/lib/ui/styles.sh"
  source "${_DEBNAS_ROOT}/lib/ui/menu.sh"
fi

# ==================== i18n ====================

_debnas_lang="${DEBNAS_LANG:-zh}"
if [[ -f "${_DEBNAS_ROOT}/lib/i18n/${_debnas_lang}.sh" ]]; then
  source "${_DEBNAS_ROOT}/lib/i18n/${_debnas_lang}.sh"
else
  source "${_DEBNAS_ROOT}/lib/i18n/zh.sh"
fi
unset _debnas_lang

# ==================== Module Registry ====================

source "${_DEBNAS_ROOT}/lib/system/module-registry.sh"

# ==================== 自动注册临时文件清理 ====================

register_temp_cleanup

# ==================== 完成标记 ====================

_DEBNAS_BOOTSTRAPPED=1
