#!/usr/bin/env bats
# 测试: modules/cockpit.sh — 集成级语法+元数据验证 (TC-P1-MOD-001)

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/cockpit.sh"

@test "cockpit: bash -n 语法通过 (TC-P1-MOD-001)" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "cockpit: @module 元数据已声明" {
  grep -q '^# @module: cockpit' "$MODULE_FILE"
}
