#!/usr/bin/env bats
# 测试: lib/core/colors.sh — 颜色定义

load '../../helpers/common-setup'

setup() {
  # 强制禁用颜色以便测试
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
}

@test "NO_COLOR=1 时 COLOR_RESET 为空" {
  [ -z "$COLOR_RESET" ]
}

@test "NO_COLOR=1 时 COLOR_RED 为空" {
  [ -z "$COLOR_RED" ]
}

@test "NO_COLOR=1 时所有颜色变量均为空" {
  [ -z "$COLOR_GREEN" ]
  [ -z "$COLOR_YELLOW" ]
  [ -z "$COLOR_BLUE" ]
  [ -z "$COLOR_CYAN" ]
  [ -z "$COLOR_DIM" ]
}
