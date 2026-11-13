#!/usr/bin/env bats
# 测试: lib/ui/dialog.sh — 确认框 / 提示框 / 文本输入
# 覆盖: ui_confirm / ui_alert / ui_input 非交互降级路径
# 说明: 交互式路径（/dev/tty 渲染 + read_key 导航）无法在 BATS 中测试，
#       此处覆盖非交互降级（管道输入、DEBNAS_FORCE_YES）和函数存在性

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  source "${DEBNAS_ROOT}/lib/ui/styles.sh"
  source "${DEBNAS_ROOT}/lib/ui/menu.sh"
  source "${DEBNAS_ROOT}/lib/ui/dialog.sh"
}

# ═══════════════════════════════════════════════════════════════
# ui_confirm — 非交互降级
# ═══════════════════════════════════════════════════════════════

@test "ui_confirm: 非终端 stdin → 输出 1（安全拒绝）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_confirm "确定卸载？" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "1" ]]
}

@test "ui_confirm: DEBNAS_FORCE_YES=1 → 输出 0（强制确认）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    export DEBNAS_FORCE_YES=1
    ui_confirm "确定卸载？"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "0" ]]
}

@test "ui_confirm: 带辅助说明非终端安全拒绝" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_confirm "确定卸载？" "将移除所有容器。\n正在运行的容器将被停止。" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "1" ]]
}

# ═══════════════════════════════════════════════════════════════
# ui_alert — 非交互降级
# ═══════════════════════════════════════════════════════════════

@test "ui_alert: 非终端 stdin → 直接返回 0（不阻塞）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_alert "系统不兼容" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

@test "ui_alert: 带辅助说明不崩溃" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_alert "系统不兼容" "DebNAS 需要 Debian 12+。" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════
# ui_input — 非交互降级
# ═══════════════════════════════════════════════════════════════

@test "ui_input: 非终端 stdin → 返回默认值" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_input "请输入主机名" "debnas" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "debnas" ]]
}

@test "ui_input: 非终端输入无末尾换行时不丢弃内容" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    printf "hostA" | ui_input "请输入主机名" "default"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "hostA" ]]
}

@test "ui_input: 非终端 stdin 无默认值 → 输出空" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    source "$1"/lib/ui/dialog.sh 2>/dev/null
    ui_input "请输入路径" <<<""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}
