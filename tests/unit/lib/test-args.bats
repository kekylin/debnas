#!/usr/bin/env bats
# 测试: lib/system/args.sh — 参数解析

load '../../helpers/common-setup'

setup() {
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/args.sh"
}

@test "parse_global_args 无参数成功" {
  parse_global_args
  [ "$DEBNAS_DRY_RUN" = "0" ]
  [ "$DEBNAS_FORCE_YES" = "0" ]
}

@test "parse_global_args: boolean 标志设置正确变量 (--cron/--dry-run/--yes/-y)" {
  # 合并原 4 个独立 boolean 测试 + 2 个重复（TC-P1-CFG-004）为 1 个参数化测试
  declare -A bool_cases=(
    ["--cron"]="DEBNAS_CRON_MODE"
    ["--dry-run"]="DEBNAS_DRY_RUN"
    ["--yes"]="DEBNAS_FORCE_YES"
    ["-y"]="DEBNAS_FORCE_YES"
  )
  local failures=0
  for flag in "${!bool_cases[@]}"; do
    unset "${bool_cases[$flag]}"
    parse_global_args "$flag"
    if [[ "${!bool_cases[$flag]}" != "1" ]]; then
      printf "FAIL: %s did not set %s=1\n" "$flag" "${bool_cases[$flag]}"
      failures=$((failures + 1))
    fi
  done
  [[ $failures -eq 0 ]]
}

@test "parse_global_args: value 标志设置正确变量 (--region)" {
  # parse_global_args 有状态（读配置文件），用子 shell 隔离每次迭代
  local failures=0

  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh'
    source '${DEBNAS_ROOT}/lib/core/colors.sh'
    source '${DEBNAS_ROOT}/lib/core/logging.sh'
    source '${DEBNAS_ROOT}/lib/system/args.sh'
    parse_global_args --region cn
    echo \"REGION=\$DEBNAS_REGION\"
  "
  [[ "$output" == *"REGION=cn"* ]] || { echo "FAIL: --region cn"; failures=$((failures + 1)); }

  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh'
    source '${DEBNAS_ROOT}/lib/core/colors.sh'
    source '${DEBNAS_ROOT}/lib/core/logging.sh'
    source '${DEBNAS_ROOT}/lib/system/args.sh'
    parse_global_args --region global
    echo \"REGION=\$DEBNAS_REGION\"
  "
  [[ "$output" == *"REGION=global"* ]] || { echo "FAIL: --region global"; failures=$((failures + 1)); }

  [[ $failures -eq 0 ]]
}

@test "parse_global_args: 非法标志值返回错误 (--region invalid)" {
  local failures=0

  run bash -c "
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/system/args.sh' 2>/dev/null
    parse_global_args --region invalid
  "
  [[ "$status" -ne 0 ]] || { echo "FAIL: --region invalid"; failures=$((failures + 1)); }

  [[ $failures -eq 0 ]]
}

@test "parse_global_args 保留剩余参数" {
  parse_global_args install docker-ce
  [ "${DEBNAS_REMAINING_ARGS_ARRAY[0]}" = "install" ]
  [ "${DEBNAS_REMAINING_ARGS_ARRAY[1]}" = "docker-ce" ]
}

@test "print_usage 输出用法说明" {
  result=$(print_usage)
  [[ "$result" == *"debnas"* ]]
}

@test "print_help 输出完整帮助" {
  result=$(print_help)
  [[ "$result" == *"子命令"* ]]
  [[ "$result" == *"install"* ]]
  [[ "$result" == *"doctor"* ]]
}

# ==================== TC-P1-CFG-001: CLI 覆盖 env ====================

@test "parse_global_args: CLI --region global 覆盖 env DEBNAS_REGION=cn（TC-P1-CFG-001）" {
  export DEBNAS_REGION="cn"
  parse_global_args --region global
  [[ "$DEBNAS_REGION" == "global" ]]
}

# ==================== TC-P1-CFG-002: env 覆盖默认值 ====================

@test "parse_global_args: env 变量覆盖默认值（TC-P1-CFG-002）" {
  # 默认值：file_logging=0，env 覆盖为 1
  export DEBNAS_FILE_LOGGING="1"
  parse_global_args
  [[ "$DEBNAS_FILE_LOGGING" == "1" ]]
}

@test "parse_global_args: DEBNAS_REGION env 设置被使用" {
  export DEBNAS_REGION="cn"
  parse_global_args
  [[ "$DEBNAS_REGION" == "cn" ]]
}

# ==================== TC-P1-CFG-003: 配置文件缺失回退 ====================

@test "parse_global_args: 配置文件缺失时回退到默认值（TC-P1-CFG-003）" {
  # parse_global_args 读取 /etc/debnas/debnas.conf，不存在时回退
  # 默认值：region=空, file_logging=0
  unset DEBNAS_REGION DEBNAS_FILE_LOGGING
  parse_global_args
  [[ "$DEBNAS_FILE_LOGGING" == "0" ]]
}

# ==================== 多标志组合测试 ====================

@test "parse_global_args: 多个全局标志同时设置" {
  parse_global_args --dry-run --yes --region cn
  [[ "$DEBNAS_DRY_RUN" == "1" ]]
  [[ "$DEBNAS_FORCE_YES" == "1" ]]
  [[ "$DEBNAS_REGION" == "cn" ]]
}

@test "parse_global_args: 全局标志后跟子命令参数" {
  parse_global_args --yes --region global install docker-ce
  [[ "$DEBNAS_FORCE_YES" == "1" ]]
  [[ "$DEBNAS_REGION" == "global" ]]
  [[ "${DEBNAS_REMAINING_ARGS_ARRAY[0]}" == "install" ]]
  [[ "${DEBNAS_REMAINING_ARGS_ARRAY[1]}" == "docker-ce" ]]
}

@test "parse_global_args: -- 分隔符后参数不做解析" {
  parse_global_args -- install --yes
  [[ "$DEBNAS_FORCE_YES" == "0" ]]
  [[ "${DEBNAS_REMAINING_ARGS_ARRAY[0]}" == "install" ]]
  [[ "${DEBNAS_REMAINING_ARGS_ARRAY[1]}" == "--yes" ]]
}

# ==================== --version / --help 已知行为 ====================

@test "print_version: DEBNAS_VERSION 已定义" {
  [[ -n "${DEBNAS_VERSION:-}" ]]
}

@test "parse_global_args: --version 触发 exit（需子 shell 验证）" {
  run bash -c "
    source '${DEBNAS_ROOT}/lib/system/args.sh'
    parse_global_args --version
  "
  [[ "$output" == *"DebNAS"* || "$output" == *"v202"* ]]
}

# ==================== TC-P1-SH-003: parse_global_args 读取配置一致性 ====================

@test "parse_global_args: 通过 config_read 读取 /etc/debnas/debnas.conf (TC-P1-SH-003)" {
  # parse_global_args 从全局配置文件读取 region/file_logging 默认值
  local args_sh="${DEBNAS_ROOT}/lib/system/args.sh"
  grep -qE 'config_read|debnas\.conf|source.*config' "$args_sh"
}
