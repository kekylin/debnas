#!/bin/bash
# 功能：Header 组件 — 模式 A 居中标题（内容栏为终端宽度的一半）
# 说明：渲染 "DebNAS" 居中标题，上下留呼吸空间；内容栏居中，左右留白
#       Phase 4: 紧凑模式（_UI_COMPACT_MODE=1）下左对齐、减少空行
# 依赖：$COLUMNS、$_UI_COMPACT_MODE、$_UI_CONTENT_WIDTH/$_UI_LEFT_MARGIN（由 layout.sh 设置）

set -euo pipefail
IFS=$'\n\t'

# 渲染 Header（在内容栏内居中显示 "DebNAS"，紧凑模式左对齐）
# 依赖：$COLUMNS、$_UI_COMPACT_MODE、$_UI_CONTENT_WIDTH、$_UI_LEFT_MARGIN
# 输出：stdout
ui_header() {
  if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
    local left="${_UI_BREAD_X:-${_UI_BREAD_INDENT:-5}}"
    # Phase 4 紧凑模式：左对齐，减少空行
    printf '\n'
    printf '%*sDebNAS\n' "$left" ''
    printf '\n'
  else
    local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    local width="${_UI_CONTENT_WIDTH:-$(( cols / 2 ))}"
    local left="${_UI_LEFT_MARGIN:-0}"
    local padding=$(( left + (width - 6) / 2 ))  # "DebNAS" = 6 字符
    [[ $padding -lt 0 ]] && padding=0

    # Header 上方 1 空行 + 内容栏内居中标题 + Header 与 Content 之间 2 空行
    printf '\n'
    printf '%*s%s\n' "$padding" '' "DebNAS"
    printf '\n\n'
  fi
}
