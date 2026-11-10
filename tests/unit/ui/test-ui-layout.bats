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
