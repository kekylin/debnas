#!/usr/bin/env bats
# 测试: modules/mail-account.sh — 集成级语法+元数据验证 (TC-P1-MOD-002)

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/mail-account.sh"

@test "mail-account: bash -n 语法通过 (TC-P1-MOD-002)" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "mail-account: @module 元数据已声明" {
  grep -q '^# @module: mail-account' "$MODULE_FILE"
}
