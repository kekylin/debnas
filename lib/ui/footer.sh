#!/bin/bash
# 功能：Footer 组件 — 模式 A 固定底栏
# 说明：渲染页面底部快捷键提示（左侧）+ 版本号（右侧）
# 依赖：core/colors.sh（COLOR_DIM、COLOR_RESET）

set -euo pipefail
IFS=$'\n\t'

# 渲染 Footer（模式 A 固定底栏）
# 参数：$1 — 快捷键提示字符串（如 "↑↓ 选择  Enter 确认  Q 退出"）
# 全局依赖：$COLUMNS, $DEBNAS_VERSION
# 输出：左侧快捷键（灰色）+ 右侧版本号（灰色）
ui_footer() {
  local shortcuts="${1:-}"
  local version="v${DEBNAS_VERSION:-3.0.0}"
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"

  # 计算右侧版本号的起始列（左侧 2 空格缩进 + 快捷键 + 2 空格间距 + 版本号）
  local padding=$((cols - ${#shortcuts} - ${#version} - 4))

  if [[ "$padding" -lt 1 ]]; then
    # 屏幕太窄：快捷键和版本号各占一行
    printf "%b  %s%b\n" "$COLOR_DIM" "$shortcuts" "$COLOR_RESET"
    printf "%b%*s%b\n" "$COLOR_DIM" "$((cols - ${#version}))" "$version" "$COLOR_RESET"
  else
    printf "%b  %s%*s%b\n" "$COLOR_DIM" "$shortcuts" "$padding" "$version" "$COLOR_RESET"
  fi
}