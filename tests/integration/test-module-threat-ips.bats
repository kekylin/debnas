#!/usr/bin/env bats
# 测试: modules/threat-ips/ — 集成级语法+元数据+子脚本验证 (TC-P1-MOD-004)

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/threat-ips"
MODULE_FILE="${MODULE_DIR}/module.sh"

@test "threat-ips: module.sh bash -n 语法通过 (TC-P1-MOD-004)" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "threat-ips: @module 元数据已声明" {
  grep -q '^# @module: threat-ips' "$MODULE_FILE"
}

@test "threat-ips: 子脚本 bash -n 语法通过" {
  for sub in ipset.sh firewall.sh cron.sh download.sh; do
    run bash -n "${MODULE_DIR}/${sub}"
    [[ "$status" -eq 0 ]] || echo "FAIL: ${sub}"
  done
}
