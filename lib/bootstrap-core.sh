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

# 项目根目录：同一 shell 中 bootstrap.sh / bin 入口已算出（_DEBNAS_ROOT，未导出、规范化路径）
# 且确实指向本文件所在仓库时直接复用（-ef 比较 inode，省一次子 shell）
if [[ -n "${_DEBNAS_ROOT:-}" && "${BASH_SOURCE[0]}" -ef "${_DEBNAS_ROOT}/lib/bootstrap-core.sh" ]]; then
  DEBNAS_ROOT="$_DEBNAS_ROOT"
elif [[ "${BASH_SOURCE[0]}" == */* ]]; then
  DEBNAS_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
else
  DEBNAS_ROOT="$(cd .. && pwd)"
fi
export DEBNAS_ROOT
_DEBNAS_ROOT="$DEBNAS_ROOT"  # 向后兼容旧代码

# 确保系统关键路径在 PATH 中（非登录 shell / cron 环境下 /usr/sbin 可能缺失）
# 只把缺失的目录追加到末尾，不整体前置：调用方放在前面的目录（root 自己的 PATH、测试 mock 目录）
# 保持优先。root 的 PATH 由 root 自己控制，追加已足以解决 cron（PATH=/usr/bin:/bin）下缺 sbin 的问题。
for _debnas_path_dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [[ ":${PATH:-}:" == *":${_debnas_path_dir}:"* ]] || PATH="${PATH:+${PATH}:}${_debnas_path_dir}"
done
unset _debnas_path_dir

# ==================== Core layer（零依赖） ====================
source "${_DEBNAS_ROOT}/lib/core/constants.sh"
source "${_DEBNAS_ROOT}/lib/core/colors.sh"
source "${_DEBNAS_ROOT}/lib/core/logging.sh"

# ==================== 基础 System layer ====================
source "${_DEBNAS_ROOT}/lib/system/layout.sh"
source "${_DEBNAS_ROOT}/lib/system/manifest.sh"
source "${_DEBNAS_ROOT}/lib/system/backup.sh"
source "${_DEBNAS_ROOT}/lib/system/utils.sh"
source "${_DEBNAS_ROOT}/lib/system/dependency.sh"
source "${_DEBNAS_ROOT}/lib/system/tempfile.sh"
source "${_DEBNAS_ROOT}/lib/system/urls.sh"
source "${_DEBNAS_ROOT}/lib/system/apt-pinning.sh"
source "${_DEBNAS_ROOT}/lib/system/apt.sh"
source "${_DEBNAS_ROOT}/lib/system/service.sh"
source "${_DEBNAS_ROOT}/lib/system/keyring.sh"

# ==================== 自动注册临时文件清理 ====================
register_temp_cleanup

_DEBNAS_CORE_LOADED=1
