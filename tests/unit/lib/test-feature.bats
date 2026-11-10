#!/usr/bin/env bats
# 测试: lib/system/feature.sh — 模块功能启用状态

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib
  export DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/features"
  source "${DEBNAS_ROOT}/lib/system/feature.sh"
}

teardown() {
  rm -rf "${DEBNAS_FEATURE_DIR}"
}

@test "feature_enable: 写入启用状态" {
  feature_enable "test-module"
  [[ "$(cat "${DEBNAS_FEATURE_DIR}/test-module.enabled")" == "1" ]]
}

@test "feature_enabled: 未启用返回 1" {
  run feature_enabled "test-module"
  [[ "$status" -ne 0 ]]
}

@test "feature_enabled: 启用后返回 0" {
  feature_enable "test-module"
  feature_enabled "test-module"
}

@test "feature_disable: 写入禁用状态" {
  feature_enable "test-module"
  feature_disable "test-module"
  [[ "$(cat "${DEBNAS_FEATURE_DIR}/test-module.enabled")" == "0" ]]
  run feature_enabled "test-module"
  [[ "$status" -ne 0 ]]
}
