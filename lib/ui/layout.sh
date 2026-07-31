#!/bin/bash
# 功能：布局组件 — 模式 A 全屏布局管理
# 说明：管理终端清屏、全屏布局、光标显示/隐藏
#       Phase 4: SIGWINCH 处理、小屏兼容、tput 回退
#       Phase 5: 光标保存/恢复（导航零 scrollback）+ 菜单快照（审计轨迹）
# 依赖：header.sh（ui_header）

set -euo pipefail
IFS=$'\n\t'

# ═══════════════════════════════════════════════════════════════
# 终端能力抽象 — tput 回退机制（Phase 4.3）
# ═══════════════════════════════════════════════════════════════

cursor_hide() {
  tput civis 2>/dev/null || printf '\033[?25l'
}

cursor_show() {
  tput cnorm 2>/dev/null || printf '\033[?25h'
}

cursor_move() {
  tput cup "$1" "$2" 2>/dev/null || printf '\033[%d;%dH' "$(( $1 + 1 ))" "$(( $2 + 1 ))"
}

# ═══════════════════════════════════════════════════════════════
# 终端尺寸检测与小屏兼容（Phase 4.2）
# ═══════════════════════════════════════════════════════════════

ui_detect_size() {
  COLUMNS=$(tput cols 2>/dev/null || echo 80)
  LINES=$(tput lines 2>/dev/null || echo 24)
}

ui_is_compact_mode() {
  local cols="${COLUMNS:-80}"
  local lines="${LINES:-24}"
  [[ "$cols" -lt 70 || "$lines" -lt 20 ]]
}

_UI_COMPACT_MODE=0
_UI_BREAD_INDENT=5
_UI_ITEM_INDENT=7
_UI_COMPACT_INDENT=4

# 光标保存标志：1=已保存（导航模式），0=未保存（模块执行后模式）
declare -g _UI_CURSOR_SAVED=0

# ═══════════════════════════════════════════════════════════════
# SIGWINCH 处理（Phase 4.1）
# ═══════════════════════════════════════════════════════════════

_UI_LAST_FOOTER=""
_UI_NEEDS_REDRAW=0

ui_handle_resize() {
  ui_detect_size
  # 终端尺寸变化后，光标保存的位置可能无效，重置标志
  _UI_CURSOR_SAVED=0
  printf '\033[H\033[J'
  ui_header
  _UI_NEEDS_REDRAW=1
}

# ═══════════════════════════════════════════════════════════════
# 布局函数
# ═══════════════════════════════════════════════════════════════

ui_screen_clear() {
  printf '\033[H\033[J'
}

# 【跨级切菜单】使用光标恢复定位旧菜单区域，原地覆写
# 光标保存/恢复比 DSR 更可靠：不受模块输出导致的终端滚动影响
ui_screen_switch() {
  if [[ "${_UI_CURSOR_SAVED:-0}" -eq 1 ]]; then
    # 导航模式：恢复到保存的位置（旧菜单起始行上方），擦除旧内容
    printf '\033[u'        # 恢复光标到保存位置
    printf '\033[J'        # 擦除从光标到屏底
    _UI_CURSOR_SAVED=0
  else
    # 无保存位置（启动/resize 等场景）：回退全清
    printf '\033[H\033[J'
  fi
  ui_screen_init
}

# 【清除菜单区】从保存的光标位置（菜单底部）向上清除 count 行
# 光标移回菜单顶部，避免依赖不可靠的 DSR 光标查询
ui_clear_menu_area() {
  local count=$1
  [[ "$count" -gt 0 ]] || return 0
  if [[ "${_UI_CURSOR_SAVED:-0}" -eq 1 ]]; then
    printf '\033[u'
    [[ $count -gt 1 ]] && printf '\033[%dA' "$((count - 1))"
    printf '\033[J'
    _UI_CURSOR_SAVED=0
  fi
  return 0
}

# 【进入菜单时】检测终端、注册信号、渲染 Header 并隐藏光标
# 调用时机：每次进入/返回菜单时调用（含同级返回、跨级切换）
ui_screen_init() {
  local footer_text="${1:-}"
  _UI_LAST_FOOTER="$footer_text"

  # 模块输出后旧保存位置已失效，以当前光标位置为基准重绘
  _UI_CURSOR_SAVED=0

  ui_detect_size

  if ui_is_compact_mode; then
    _UI_COMPACT_MODE=1
  else
    _UI_COMPACT_MODE=0
  fi

  trap 'ui_handle_resize' SIGWINCH

  printf '\033[J'
  ui_header

  # 保存光标位置（在 Header 之后、菜单项之前）
  # 供 ui_screen_switch 的 \033[u 恢复使用，实现导航零 scrollback
  printf '\033[s'
  _UI_CURSOR_SAVED=1

  cursor_hide
  _ui_register_cursor_trap
}

_ui_register_cursor_trap() {
  if [[ "${_UI_CURSOR_TRAP_SET:-0}" -eq 1 ]]; then
    return 0
  fi
  local current
  current=$(trap -p EXIT 2>/dev/null || true)
  if [[ -z "$current" ]]; then
    trap 'cursor_show 2>/dev/null || printf "\033[?25h"' EXIT
  else
    local existing_cmd
    existing_cmd=$(echo "$current" | sed -n "s/^trap -- '\\(.*\\)' EXIT$/\\1/p")
    if [[ -n "$existing_cmd" ]]; then
      trap 'cursor_show 2>/dev/null || printf "\033[?25h"; '"$existing_cmd" EXIT
    fi
  fi
  _UI_CURSOR_TRAP_SET=1
}

ui_cursor_show() {
  cursor_show
  printf '\n'
}

# ═══════════════════════════════════════════════════════════════
# 菜单快照（Phase 5 — scrollback 审计轨迹）
# ═══════════════════════════════════════════════════════════════

declare -g -a _UI_MENU_SNAPSHOT_ITEMS=()
declare -g _UI_MENU_SNAPSHOT_FOCUSED=0
declare -g _UI_MENU_SNAPSHOT_BREADCRUMB=""

# 打印菜单快照到终端（格式与真实菜单一致）
_ui_print_menu_snapshot() {
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local bc="${_UI_MENU_SNAPSHOT_BREADCRUMB:-}"
  local focused="${_UI_MENU_SNAPSHOT_FOCUSED:-0}"

  cursor_show 2>/dev/null || printf '\033[?25h'

  # Header
  if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
    printf '\n'
    printf '%*sDebNAS\n' "${_UI_BREAD_INDENT:-2}" ''
    printf '\n'
  else
    local padding=$(( (cols - 6) / 2 ))
    [[ $padding -lt 0 ]] && padding=0
    printf '\n'
    printf '%*s%s\n' "$padding" '' "DebNAS"
    printf '\n\n'
  fi

  # 面包屑
  if [[ -n "$bc" ]]; then
    printf '%*s%b%s%b\n' "$_UI_BREAD_INDENT" '' "${COLOR_DIM:-}" "$bc" "${COLOR_RESET:-}"
    if [[ "${_UI_COMPACT_MODE:-0}" -eq 0 ]]; then
      printf '\n'
    fi
  fi

  # 菜单项
  local i item
  for i in "${!_UI_MENU_SNAPSHOT_ITEMS[@]}"; do
    item="${_UI_MENU_SNAPSHOT_ITEMS[$i]}"
    if [[ "$i" -eq "$focused" ]]; then
      printf '%*s%b> %s%b\n' "$_UI_BREAD_INDENT" '' "${COLOR_CYAN:-}" "$item" "${COLOR_RESET:-}"
    else
      printf '%*s%s\n' "$_UI_ITEM_INDENT" '' "$item"
    fi
  done

  # Footer
  local shortcuts="↑↓ 选择  Enter 确认"
  if [[ -n "$bc" ]]; then
    shortcuts+="  Esc 返回"
  else
    shortcuts+="  Q 退出"
  fi
  local version="v${DEBNAS_VERSION:-3.0.0}"
  local margin="${_UI_BREAD_INDENT:-2}"
  local ftr_padding=$((cols - margin - ${#shortcuts} - ${#version} - 2))
  if [[ "$ftr_padding" -lt 1 ]]; then
    printf "%b%*s%s%b\n" "${COLOR_DIM:-}" "$margin" '' "$shortcuts" "${COLOR_RESET:-}"
  else
    printf "%b%*s%s%*s%b\n" "${COLOR_DIM:-}" "$margin" '' "$shortcuts" "$ftr_padding" "$version" "${COLOR_RESET:-}"
  fi

  # 光标保存位置已失效（快照改变了光标位置）
  _UI_CURSOR_SAVED=0
}

# ═══════════════════════════════════════════════════════════════
# 无障碍播报（DEBNAS_ACCESSIBILITY=1）
# Phase 5: 屏幕阅读器友好的状态文字输出
# ═══════════════════════════════════════════════════════════════

# 无障碍状态播报（仅 DEBNAS_ACCESSIBILITY=1 时输出到 stderr）
# 参数：$1 — 播报内容
# 输出：stderr（不影响 TUI 渲染的 /dev/tty 游标定位）
_ui_a11y_announce() {
  [[ "${DEBNAS_ACCESSIBILITY:-0}" -eq 1 ]] || return 0
  printf '[DebNAS] %s\n' "$*" >&2
}
