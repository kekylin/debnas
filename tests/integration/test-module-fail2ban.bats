#!/usr/bin/env bats
# 测试: modules/fail2ban.sh — 集成级语法+元数据验证 (TC-P1-MOD-003)

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/fail2ban.sh"

@test "fail2ban: bash -n 语法通过 (TC-P1-MOD-003)" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "fail2ban: @module 元数据已声明" {
  grep -q '^# @module: fail2ban' "$MODULE_FILE"
}
