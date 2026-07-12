#!/bin/bash
# 功能：布局组件 — 模式 A 全屏布局管理
# 说明：管理终端清屏、全屏布局、光标显示/隐藏
# 依赖：header.sh（ui_header）

set -euo pipefail
IFS=$'\n\t'

# 【首次启动】清屏（仅在 main() 启动时调用一次）
ui_screen_clear() {
  clear 2>/dev/null || printf '\033[2J\033[H'
}

# 【进入菜单时】渲染 Header 并隐藏光标
# 说明：Content 区域由 ui_menu 负责渲染，Footer（快捷键提示）由 ui_menu 底部标签承载
# 调用时机：每次进入/返回菜单时调用
ui_screen_init() {
  ui_header
  # 隐藏光标（减少闪烁）
  tput civis 2>/dev/null || printf '\033[?25l'
}

# 恢复光标显示（退出程序时调用）
ui_cursor_show() {
  tput cnorm 2>/dev/null || printf '\033[?25h'
  printf '\n'
}
