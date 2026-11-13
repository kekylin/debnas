#!/usr/bin/env bats
# 测试: lib/ui/layout.sh — 终端尺寸检测 / 小屏判断 / 光标控制
# 覆盖: ui_detect_size / ui_is_compact_mode / cursor_hide / cursor_show / cursor_move

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  source "${DEBNAS_ROOT}/lib/ui/styles.sh"
  source "${DEBNAS_ROOT}/lib/ui/header.sh"
  source "${DEBNAS_ROOT}/lib/ui/footer.sh"
  source "${DEBNAS_ROOT}/lib/ui/layout.sh"
}

# ═══════════════════════════════════════════════════════════════
# ui_detect_size — 终端尺寸检测
# ═══════════════════════════════════════════════════════════════

@test "ui_detect_size: 设置 COLUMNS 和 LINES 为数值" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    ui_detect_size
    echo "COLUMNS=$COLUMNS"
    echo "LINES=$LINES"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  # 非交互 shell 中 tput 可能失败，回退到 80/24
  [[ "$output" =~ COLUMNS=[0-9]+ ]]
  [[ "$output" =~ LINES=[0-9]+ ]]
}

# ═══════════════════════════════════════════════════════════════
# ui_is_compact_mode — 小屏判断
# ═══════════════════════════════════════════════════════════════

@test "ui_is_compact_mode: 宽屏（80×24）→ 返回 1（非小屏）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=80 LINES=24
    ui_is_compact_mode && echo "compact" || echo "normal"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "normal" ]]
}

@test "ui_is_compact_mode: 窄屏（COLUMNS=60）→ 返回 0（小屏）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=60 LINES=24
    ui_is_compact_mode && echo "compact" || echo "normal"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "compact" ]]
}

@test "ui_is_compact_mode: 矮屏（LINES=18）→ 返回 0（小屏）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=80 LINES=18
    ui_is_compact_mode && echo "compact" || echo "normal"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "compact" ]]
}

# ═══════════════════════════════════════════════════════════════
# cursor 辅助函数 — 存在性与调用不崩溃
# ═══════════════════════════════════════════════════════════════

@test "cursor_hide: 函数存在且调用不崩溃" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    cursor_hide
    echo "ok"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ok"* ]]
}

@test "cursor_show: 函数存在且调用不崩溃" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    cursor_show
    echo "ok"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ok"* ]]
}

@test "cursor_move: 函数存在且调用不崩溃" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    cursor_move 0 0
    echo "ok"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ok"* ]]
}

# ═══════════════════════════════════════════════════════════════
# ui_header 紧凑模式
# ═══════════════════════════════════════════════════════════════

@test "ui_header: 紧凑模式左对齐不含长空格" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    _UI_COMPACT_MODE=1 ui_header
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  # 紧凑模式：左对齐 "  DebNAS"
  [[ "$output" == *"  DebNAS"* ]]
}

# ═══════════════════════════════════════════════════════════════
# 终端尺寸变化（SIGWINCH）与重绘
# ═══════════════════════════════════════════════════════════════

@test "ui_handle_resize: 只清屏并置重绘标志，不自行打印 Header" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=80 LINES=24
    _UI_NEEDS_REDRAW=0
    ui_handle_resize
    printf "FLAG=%s CURSOR_SAVED=%s\n" "$_UI_NEEDS_REDRAW" "$_UI_CURSOR_SAVED"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  # Header 由界面自身的 REDRAW 分支重绘；信号处理里重复打印会与重绘内容叠在一起
  [[ "$output" != *"DebNAS"* ]]
  [[ "$output" == *"FLAG=1 CURSOR_SAVED=0"* ]]
}

@test "ui_screen_init: 重新渲染后清除待重绘标志" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=80 LINES=24
    _UI_NEEDS_REDRAW=1
    ui_screen_init >/dev/null 2>&1
    echo "FLAG=$_UI_NEEDS_REDRAW"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"FLAG=0"* ]]
}

@test "ui_menu: REDRAW 分支清屏后整屏重绘 Header 与菜单" {
  local f="${DEBNAS_ROOT}/lib/ui/menu.sh"
  local block
  block=$(grep -A 20 '^      REDRAW)' "$f")
  [[ -n "$block" ]]
  grep -qF "printf '\033[H\033[J'" <<< "$block"
  grep -q 'ui_header' <<< "$block"
  grep -q '_ui_menu_full_redraw' <<< "$block"
}

@test "ui_menu: 旧焦点滚出可视区时先整块清除再重绘" {
  local f="${DEBNAS_ROOT}/lib/ui/menu.sh"
  grep -qF "printf '\r\033[J'" "$f"
}

@test "ui_footer: 快捷键与版本号之间至少保留 2 个空格" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=120; _ui_compute_width
    DEBNAS_VERSION=v2026.11.1
    ui_footer "↑↓ 选择  Enter 确认  Q 退出"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"v2026.11.1"* ]]
  # printf 的 %*s 宽度小于版本号长度时不补空格，曾出现 "Q 退出v2026.11.1"
  [[ ! "$output" =~ 退出v2026 ]]
  [[ "$output" =~ 退出\ {2,}v2026\.11\.1 ]]
}

@test "ui_footer: 有新版本时版本号前显示绿点" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=120; _ui_compute_width
    DEBNAS_VERSION=v2026.11.1
    _UI_FOOTER_UPDATE_DOT=1
    ui_footer "↑↓ 选择  Enter 确认  Q 退出"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"● v2026.11.1"* ]]
}

@test "ui_footer: 没有新版本时不显示绿点" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/header.sh 2>/dev/null
    source "$1"/lib/ui/footer.sh 2>/dev/null
    source "$1"/lib/ui/layout.sh 2>/dev/null
    COLUMNS=120; _ui_compute_width
    DEBNAS_VERSION=v2026.11.1
    _UI_FOOTER_UPDATE_DOT=0
    ui_footer "↑↓ 选择  Enter 确认  Q 退出"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"v2026.11.1"* ]]
  [[ "$output" != *"●"* ]]
}

@test "ui_menu: 绿点只在没有面包屑的一级菜单显示（二级菜单不显示）" {
  local body
  body=$(sed -n '/_ui_menu_render_all()/,/^  }/p' "${DEBNAS_ROOT}/lib/ui/menu.sh")
  [[ -n "$body" ]]
  [[ "$body" == *'-z "$breadcrumb"'* ]]
  [[ "$body" == *'_UI_FOOTER_UPDATE_DOT=1'* ]]
  [[ "$body" == *'_UI_FOOTER_UPDATE_DOT=0'* ]]
}
