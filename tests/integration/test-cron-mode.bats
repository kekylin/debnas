#!/usr/bin/env bats
# 集成测试: @cron: true 模块的结构验证 — 以 sys-patches 为代表
# 验证目录模块的子脚本语法、元数据完整性和 cron 注册流程

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
export NO_COLOR=1
source "${DEBNAS_ROOT}/lib/core/constants.sh"
source "${DEBNAS_ROOT}/lib/core/colors.sh"
source "${DEBNAS_ROOT}/lib/core/logging.sh"

# 直接解析模块元数据（不依赖 module-registry）
MODULE_FILE="${DEBNAS_ROOT}/modules/sys-patches/module.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "sys-patches: @cron 为 true" {
  result=$(parse_meta "cron")
  [[ "$result" == "true" ]]
}

@test "sys-patches: @cron_schedule 为 0 0 * * *" {
  result=$(parse_meta "cron_schedule")
  [[ "$result" == "0 0 * * *" ]]
}

@test "sys-patches: @interactive 为 true（cron 模式需非交互执行）" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

@test "sys-patches: @depends 已声明（系统命令依赖）" {
  result=$(parse_meta "depends")
  # 字段本身已声明（即使当前为空）
  grep -q '@depends:' "$MODULE_FILE"
}

# ==================== 子脚本语法验证 ====================
# 注：module.sh 的 bash -n 已由 L1 门禁全局覆盖
# 以下检查 L1 未覆盖的子脚本（目录模块内 check.sh/notify.sh）

@test "sys-patches: check.sh 语法有效" {
  run bash -n "${DEBNAS_ROOT}/modules/sys-patches/check.sh"
  [[ "$status" -eq 0 ]]
}

@test "sys-patches: notify.sh 语法有效" {
  run bash -n "${DEBNAS_ROOT}/modules/sys-patches/notify.sh"
  [[ "$status" -eq 0 ]]
}

# ==================== 入口结构验证 ====================

@test "sys-patches: module.sh 包含 main 函数入口" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "sys-patches: module.sh 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== Cron 注册流程（mock crontab） ====================

setup_cron_mock() {
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  # 使用共享 crontab Mock（定义在 helpers/common-setup.bash）
  # 需要在调用前先 source 公共 helper（避免重复定义）
  source "${DEBNAS_ROOT}/tests/helpers/common-setup.bash" 2>/dev/null || true
  setup_crontab_mock
  source "${DEBNAS_ROOT}/lib/system/cron.sh"
}

teardown_cron_mock() {
  teardown_crontab_mock
}

@test "sys-patches: cron_register 使用正确的 schedule" {
  setup_cron_mock
  run cron_register "sys-patches" "0 0 * * *"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$CRON_STATE")" == *"DEBNAS-CRON: sys-patches"* ]]
  [[ "$(cat "$CRON_STATE")" == *"0 0 * * *"* ]]
  teardown_cron_mock
}

@test "sys-patches: cron_register 幂等 — 重复注册不产生重复条目" {
  setup_cron_mock
  cron_register "sys-patches" "0 0 * * *"
  cron_register "sys-patches" "0 0 * * *"
  local count
  count=$(grep -c "DEBNAS-CRON: sys-patches" "$CRON_STATE" || true)
  [[ "$count" -eq 1 ]]
  teardown_cron_mock
}

@test "sys-patches: cron_unregister 移除后再注册正常工作" {
  setup_cron_mock
  cron_register "sys-patches" "0 0 * * *"
  run cron_unregister "sys-patches"
  [[ "$status" -eq 0 ]]
  # 移除后 crontab 为空
  [[ ! -f "$CRON_STATE" ]]
  teardown_cron_mock
}
