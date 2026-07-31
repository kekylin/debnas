#!/bin/bash
# 功能：Header 组件 — 模式 A 居中标题
# 说明：渲染 "DebNAS" 居中标题，上下留呼吸空间
#       Phase 4: 紧凑模式（_UI_COMPACT_MODE=1）下左对齐、减少空行
# 依赖：$COLUMNS、$_UI_COMPACT_MODE（由 layout.sh 设置）

set -euo pipefail
IFS=$'\n\t'

# 渲染 Header（居中显示 "DebNAS"，紧凑模式左对齐）
# 依赖：$COLUMNS（终端宽度）、$_UI_COMPACT_MODE（紧凑模式标志）
# 输出：stdout
ui_header() {
  if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
    # Phase 4 紧凑模式：左对齐，减少空行
    printf '\n'
    printf '%*sDebNAS\n' "${_UI_BREAD_INDENT:-2}" ''
    printf '\n'
  else
    local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    local padding=$(( (cols - 6) / 2 ))  # "DebNAS" = 6 字符
    [[ $padding -lt 0 ]] && padding=0

    # Header 上方 1 空行 + 居中标题 + Header 与 Content 之间 2 空行
    printf '\n'
    printf '%*s%s\n' "$padding" '' "DebNAS"
    printf '\n\n'
  fi
}
