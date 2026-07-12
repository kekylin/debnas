#!/bin/bash
# 功能：Header 组件 — 模式 A 居中标题
# 说明：渲染 "DebNAS" 居中标题，上下留呼吸空间
# 依赖：无（仅使用 $COLUMNS 和 tput）

set -euo pipefail
IFS=$'\n\t'

# 渲染 Header（居中显示 "DebNAS"）
# 依赖：$COLUMNS（终端宽度）
# 输出：stdout
ui_header() {
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local padding=$(( (cols - 6) / 2 ))  # "DebNAS" = 6 字符
  [[ $padding -lt 0 ]] && padding=0

  # Header 上方呼吸空间 + 居中标题 + Header 与 Content 之间呼吸空间
  printf '\n\n\n'
  printf '%*s%s\n' "$padding" '' "DebNAS"
  printf '\n\n'
}
