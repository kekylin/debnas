#!/usr/bin/env bats
# 测试: lib/ui/menu.sh — 按键读取（read_key）
# 技术: stdin 注入

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # styles.sh 依赖 colors.sh（已由 setup_debnas_lib 加载）
  source "${DEBNAS_ROOT}/lib/ui/styles.sh"
  source "${DEBNAS_ROOT}/lib/ui/menu.sh"
}

# ==================== read_key: 方向键连发 ====================

@test "read_key: 连续下方向键逐次解析为 DOWN（不吞序列）" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    printf "\033[B\033[B\033[B" | {
      read_key; echo "1=$_READ_KEY_RESULT"
      read_key; echo "2=$_READ_KEY_RESULT"
      read_key; echo "3=$_READ_KEY_RESULT"
    }
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"1=DOWN"* ]]
  [[ "$output" == *"2=DOWN"* ]]
  [[ "$output" == *"3=DOWN"* ]]
}

@test "read_key: 纯 ESC 仍返回 ESC" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    source "$1"/lib/core/colors.sh 2>/dev/null
    source "$1"/lib/core/logging.sh 2>/dev/null
    source "$1"/lib/ui/styles.sh 2>/dev/null
    source "$1"/lib/ui/menu.sh 2>/dev/null
    printf "\033" | {
      read_key
      echo "$_READ_KEY_RESULT"
    }
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ESC"* ]]
}

