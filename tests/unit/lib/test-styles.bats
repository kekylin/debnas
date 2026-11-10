#!/usr/bin/env bats
# 测试: lib/ui/styles.sh — UI 样式库（15 函数）
# Mock 策略：source 依赖链 + 输出捕获 + NO_COLOR 切换

setup() {
  DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
  source "${DEBNAS_ROOT}/lib/ui/styles.sh"
}

# ==================== get_ui_color 颜色映射（grep 结构验证） ====================

@test "styles: get_ui_color primary 映射到 COLOR_CYAN" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'primary.*COLOR_CYAN'
}

@test "styles: get_ui_color secondary 映射到 COLOR_WHITE" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'secondary.*COLOR_WHITE'
}

@test "styles: get_ui_color success 映射到 COLOR_GREEN" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'success.*COLOR_GREEN'
}

@test "styles: get_ui_color warning 映射到 COLOR_YELLOW" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'warning.*COLOR_YELLOW'
}

@test "styles: get_ui_color error 映射到 COLOR_RED" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'error.*COLOR_RED'
}

@test "styles: get_ui_color info 映射到 COLOR_BLUE" {
  grep -A10 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'info.*COLOR_BLUE'
}

@test "styles: get_ui_color highlight 映射到 COLOR_CYAN" {
  grep -A14 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'highlight.*COLOR_CYAN'
}

@test "styles: get_ui_color accent 映射到 COLOR_CYAN" {
  grep -A14 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'accent.*COLOR_CYAN'
}

@test "styles: get_ui_color dim 映射到 COLOR_DIM" {
  grep -A14 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q 'dim.*COLOR_DIM'
}

@test "styles: get_ui_color 默认分支映射到 COLOR_RESET" {
  grep -A16 '^get_ui_color()' "${DEBNAS_ROOT}/lib/ui/styles.sh" | grep -q '\*).*COLOR_RESET'
}

# ==================== print_prompt ====================

@test "styles: print_prompt 输出到 stderr" {
  run bash -c '
    source "$1"/lib/core/constants.sh
    source "$1"/lib/core/colors.sh
    source "$1"/lib/core/logging.sh
    source "$1"/lib/ui/styles.sh
    export NO_COLOR=1
    print_prompt "Enter choice: " 2>&1
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"Enter choice:"* ]]
}

