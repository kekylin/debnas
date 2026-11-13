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
  _ui_compute_width
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

# 内容栏宽度：终端宽度的一半，居中显示（经典菜单的界面宽度）
_UI_CONTENT_WIDTH=0
_UI_LEFT_MARGIN=0
_UI_BREAD_X=5
_UI_ITEM_X=7
_UI_COMPACT_X=4

_ui_compute_width() {
  local cols="${COLUMNS:-80}"
  _UI_CONTENT_WIDTH=$(( cols / 2 ))
  (( _UI_CONTENT_WIDTH < 20 )) && _UI_CONTENT_WIDTH=20
  (( _UI_CONTENT_WIDTH > cols )) && _UI_CONTENT_WIDTH=$cols
  # 内容栏靠左，不做整体居中
  _UI_LEFT_MARGIN=0
  _UI_BREAD_X=$_UI_BREAD_INDENT
  _UI_ITEM_X=$_UI_ITEM_INDENT
  _UI_COMPACT_X=$_UI_COMPACT_INDENT
}

# 单个字符的显示宽度（CJK 双宽）→ _UI_CHAR_W
_UI_CHAR_W=1
_ui_char_width() {
  local c="$1" cp
  if [[ "$c" == [\ -~] ]]; then _UI_CHAR_W=1; return 0; fi
  printf -v cp '%d' "'$c" 2>/dev/null || { _UI_CHAR_W=1; return 0; }
  if (( (cp >= 0x1100 && cp <= 0x115F) \
    || (cp >= 0x2E80 && cp <= 0x303E) || (cp >= 0x3041 && cp <= 0x33FF) \
    || (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) \
    || (cp >= 0xA000 && cp <= 0xA4CF) || (cp >= 0xAC00 && cp <= 0xD7A3) \
    || (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0xFE30 && cp <= 0xFE6F) \
    || (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) \
    || (cp >= 0x1F300 && cp <= 0x1F64F) || (cp >= 0x1F900 && cp <= 0x1F9FF) \
    || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
    _UI_CHAR_W=2
  else
    _UI_CHAR_W=1
  fi
}

# 按显示宽度截断文本（超宽时末尾加 …），结果写入 _UI_FIT_TEXT / _UI_FIT_WIDTH
_UI_FIT_TEXT=""
_UI_FIT_WIDTH=0
_ui_fit_text() {
  local s="$1" max="${2:-0}" out="" w=0 i c cw last
  (( max < 1 )) && { _UI_FIT_TEXT=""; _UI_FIT_WIDTH=0; return 0; }
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    _ui_char_width "$c"; cw=$_UI_CHAR_W
    if (( w + cw > max )); then
      while (( ${#out} > 0 && w + 1 > max )); do
        last="${out: -1}"
        _ui_char_width "$last"
        out="${out:0:${#out}-1}"
        w=$(( w - _UI_CHAR_W ))
      done
      out+="…"; w=$(( w + 1 ))
      break
    fi
    out+="$c"; w=$(( w + cw ))
  done
  _UI_FIT_TEXT="$out"; _UI_FIT_WIDTH=$w
}

# 光标保存标志：1=已保存（导航模式），0=未保存（模块执行后模式）
declare -g _UI_CURSOR_SAVED=0

# ═══════════════════════════════════════════════════════════════
# SIGWINCH 处理（Phase 4.1）
# ═══════════════════════════════════════════════════════════════

_UI_NEEDS_REDRAW=0

ui_handle_resize() {
  ui_detect_size
  # 终端尺寸变化后，保存的光标位置不再可信；清屏后由各界面（菜单/对话框）在
  # REDRAW 分支从屏幕顶部整屏重绘。此处不打印 Header，避免与重绘内容叠加。
  _UI_CURSOR_SAVED=0
  printf '\033[H\033[J'
  _UI_NEEDS_REDRAW=1
}

# ═══════════════════════════════════════════════════════════════
# 布局函数
# ═══════════════════════════════════════════════════════════════

ui_screen_clear() {
  printf '\033[H\033[J'
}

# 计算当前菜单区总行数（Header + 面包屑 + 菜单项 + 底部标签）
_ui_menu_area_height() {
  local header_height=4 breadcrumb_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && { header_height=3; breadcrumb_lines=1; }
  local item_count=${#_UI_MENU_SNAPSHOT_ITEMS[@]}
  [[ -z "${_UI_MENU_SNAPSHOT_BREADCRUMB:-}" ]] && breadcrumb_lines=0
  echo $(( header_height + breadcrumb_lines + item_count + 1 ))
}

# 【跨级切菜单】使用光标恢复定位旧菜单区域，原地覆写
# 光标保存/恢复比 DSR 更可靠：不受模块输出导致的终端滚动影响
ui_screen_switch() {
  if [[ "${_UI_CURSOR_SAVED:-0}" -eq 1 ]]; then
    # 恢复到菜单底部，再上移到菜单顶部，整块擦除旧菜单
    local area_height
    area_height=$(_ui_menu_area_height)
    printf '\033[u'
    printf '\033[%dA' "$area_height"
    printf '\033[J'
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
    printf '\033[%dA' "$count"
    printf '\033[J'
    _UI_CURSOR_SAVED=0
  fi
  return 0
}

# 【进入菜单时】检测终端、注册信号、渲染 Header 并隐藏光标
# 调用时机：每次进入/返回菜单时调用（含同级返回、跨级切换）
ui_screen_init() {
  # 模块输出后旧保存位置已失效，以当前光标位置为基准重绘
  _UI_CURSOR_SAVED=0
  # 此处会完整渲染 Header，先前的尺寸变化已无需要处理的重绘
  _UI_NEEDS_REDRAW=0

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
    trap 'cursor_show 2>/dev/null || printf "\033[?25h"; stty echo 2>/dev/null || true' EXIT
  else
    local existing_cmd=""
    # trap -p 输出形如 trap -- '命令' EXIT（命令内的单引号转义为 '\''）；多行命令同样适用
    if [[ "$current" == "trap -- '"*"' EXIT" ]]; then
      existing_cmd="${current#"trap -- '"}"
      existing_cmd="${existing_cmd%"' EXIT"}"
      existing_cmd="${existing_cmd//"'\\''"/"'"}"
    fi
    if [[ -n "$existing_cmd" ]]; then
      # 原有 trap（如 _debnas_cleanup_on_exit）放在最前：它通过 $? 判断退出码，
      # 若先执行 cursor_show/stty，$? 会被覆盖为 0，异常退出将不再被识别
      trap "${existing_cmd}"'; cursor_show 2>/dev/null || printf "\033[?25h"; stty echo 2>/dev/null || true' EXIT
    fi
  fi
  _UI_CURSOR_TRAP_SET=1
}

ui_cursor_show() {
  cursor_show
  printf '\n'
}

# 菜单交互期间关闭终端回显，避免方向键/ESC 序列被原样打印
_ui_terminal_echo_off() {
  [[ -t 0 ]] || return 0
  stty -echo 2>/dev/null || true
}

_ui_terminal_echo_on() {
  [[ -t 0 ]] || return 0
  stty echo 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# 菜单快照（Phase 5 — scrollback 审计轨迹）
# ═══════════════════════════════════════════════════════════════

declare -g -a _UI_MENU_SNAPSHOT_ITEMS=()
declare -g _UI_MENU_SNAPSHOT_FOCUSED=0
declare -g _UI_MENU_SNAPSHOT_BREADCRUMB=""

# 打印菜单快照到终端（格式与真实菜单一致）
_ui_print_menu_snapshot() {
  local bc="${_UI_MENU_SNAPSHOT_BREADCRUMB:-}"
  local focused="${_UI_MENU_SNAPSHOT_FOCUSED:-0}"

  cursor_show 2>/dev/null || printf '\033[?25h'
  printf '\n'
  [[ "${_UI_CONTENT_WIDTH:-0}" -gt 0 ]] || _ui_compute_width

  # Header（与 ui_header 共用半宽内容栏）
  ui_header

  # 面包屑
  if [[ -n "$bc" ]]; then
    printf '%*s%b%s%b\n' "$_UI_BREAD_X" '' "${COLOR_DIM:-}" "$bc" "${COLOR_RESET:-}"
  fi

  # 菜单项
  local i item
  for i in "${!_UI_MENU_SNAPSHOT_ITEMS[@]}"; do
    item="${_UI_MENU_SNAPSHOT_ITEMS[$i]}"
    if [[ "$i" -eq "$focused" ]]; then
      printf '%*s%b> %s%b\n' "$_UI_BREAD_X" '' "${COLOR_CYAN:-}" "$item" "${COLOR_RESET:-}"
    else
      printf '%*s%s\n' "$_UI_ITEM_X" '' "$item"
    fi
  done

  # Footer
  local shortcuts="↑↓ 选择  Enter 确认"
  if [[ -n "$bc" ]]; then
    shortcuts+="  Esc 返回"
  else
    shortcuts+="  Q 退出"
  fi
  # Footer（一级菜单且有新版本时带绿点）
  if [[ -z "$bc" && -n "${_UI_UPDATE_HINT:-}" ]]; then
    _UI_FOOTER_UPDATE_DOT=1
  else
    _UI_FOOTER_UPDATE_DOT=0
  fi
  ui_footer "$shortcuts"

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

# ═══════════════════════════════════════════════════════════════
# locale — 确保 UI 使用 UTF-8（C/POSIX 下中文按字节截断）
# ═══════════════════════════════════════════════════════════════

# 非 UTF-8 locale 且系统提供 C.UTF-8 时回退；不覆盖用户已设置的 UTF-8 locale
# 参数：无
# 返回：0（始终）
ui_ensure_utf8_locale() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8|*utf8|*utf-8) return 0 ;;
  esac
  if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
    export LC_ALL=C.UTF-8
  fi
  return 0
}
