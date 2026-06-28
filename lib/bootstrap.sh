#!/bin/bash
# bootstrap.sh — DebNAS 统一库加载入口
# 加载全部库文件（含 bootstrap-core.sh + 所有 system/ 库）
# 所有 bin/ 入口脚本和 modules/ 模块统一使用此文件

set -euo pipefail
IFS=$'\n\t'

# 防止重复加载
if [[ "${_DEBNAS_BOOTSTRAPPED:-0}" -eq 1 ]]; then
  return 0 2>/dev/null || true
fi

# 获取项目根目录
_DEBNAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ==================== 早期标志解析 ====================
_parse_early_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --cron)    export DEBNAS_CRON_MODE=1 ;;
      --dry-run) export DEBNAS_DRY_RUN=1 ;;
      --yes|-y)  export DEBNAS_FORCE_YES=1 ;;
    esac
  done
}
_parse_early_flags "$@"
unset -f _parse_early_flags

# ==================== 加载核心 + 基础系统库 ====================
source "${_DEBNAS_ROOT}/lib/bootstrap-core.sh"

# ==================== 扩展 System layer ====================
source "${_DEBNAS_ROOT}/lib/system/args.sh"
source "${_DEBNAS_ROOT}/lib/system/state.sh"
source "${_DEBNAS_ROOT}/lib/system/cron.sh"
source "${_DEBNAS_ROOT}/lib/system/config.sh"
source "${_DEBNAS_ROOT}/lib/system/installer.sh"
source "${_DEBNAS_ROOT}/lib/system/migration.sh"

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

# ==================== 完成标记 ====================
_DEBNAS_BOOTSTRAPPED=1
