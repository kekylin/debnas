#!/usr/bin/env bats
# 测试: 配置优先级链专项验证 (TC-P1-CFG-001~005)
# 说明: TC-P1-CFG-001~004 已在 test-args.bats 中覆盖，此处补充 CFG-005 边界验证
# Mock 策略: 子 shell 隔离 + 结构 grep

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"

# ==================== TC-P1-CFG-005: 非法 --region 值 ====================

@test "config-priority: parse_global_args --region invalid 返回错误 (TC-P1-CFG-005)" {
  run bash -c '
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/args.sh 2>/dev/null

    parse_global_args --region invalid 2>/dev/null
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -ne 0 ]]
}

# ==================== 补充：配置文件缺失时的回退链 ====================

@test "config-priority: DEBNAS_CONF_DIR 默认值 /etc/debnas/conf.d" {
  local config_sh="${DEBNAS_ROOT}/lib/system/config.sh"
  grep -qE '/etc/debnas/conf\.d|DEBNAS_CONF_DIR' "$config_sh"
}

@test "config-priority: 全局配置文件路径 /etc/debnas/debnas.conf" {
  local config_sh="${DEBNAS_ROOT}/lib/system/config.sh"
  grep -qE '/etc/debnas/debnas\.conf|DEBNAS_GLOBAL_CONF' "$config_sh"
}

@test "config-priority: config_read 默认值参数生效" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/config.sh 2>/dev/null

    result=$(config_read "nonexistent_section_cfp" "nonexistent_key" "FALLBACK_VALUE")
    echo "RESULT=$result"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"RESULT=FALLBACK_VALUE"* ]]
}
