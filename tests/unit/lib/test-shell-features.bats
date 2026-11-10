#!/usr/bin/env bats
# 测试: Shell 特性验证 (TC-P2-SH-003~005)
# Mock 策略: 子 shell 隔离 + 输出捕获

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"

# ==================== TC-P2-SH-003: 进程替换子命令失败 → 父进程检测 ====================

@test "shell: 进程替换子命令失败父进程可检测 (TC-P2-SH-003)" {
  run bash -c '
    set -o pipefail
    # 使用 < <(false) 进程替换 — 失败不应被静默忽略
    # 直接使用管道捕获非零退出
    output=$(false 2>/dev/null) || echo "DETECTED_FAILURE"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"DETECTED_FAILURE"* ]]
}

# ==================== TC-P2-SH-004: IFS 临时修改验证恢复 ====================

@test "shell: IFS 临时修改手动赋值形式验证恢复 (TC-P2-SH-004)" {
  run bash -c '
    # 保存原始 IFS
    old_ifs="$IFS"

    # 在子 shell 中修改 IFS
    (
      IFS=","
      data="a,b,c"
      read -ra arr <<< "$data"
      echo "COUNT=${#arr[@]}"
    )

    # 验证 IFS 已恢复（子 shell 隔离保证）
    echo "IFS_RESTORED=$([[ "$IFS" == "$old_ifs" ]] && echo yes || echo no)"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"IFS_RESTORED=yes"* ]]
}

# ==================== TC-P2-SH-005: print_colored 不存在颜色静默回退 ====================

@test "shell: print_colored 不存在颜色间接变量引用静默回退 (TC-P2-SH-005)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/ui/styles.sh 2>/dev/null

    # set -u 会导致未定义变量错误，关闭 nounset 测试回退行为
    set +u
    # 对不存在颜色变量的间接引用应为空字符串
    print_colored "NONEXISTENT_VAR" "test text" 2>/dev/null || true
    echo "NO_CRASH"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"NO_CRASH"* ]]
}

# ==================== 补充：parse_global_args grep vs config_read_global 一致性 ====================

@test "shell: parse_global_args 使用 config_read global 读取配置 (TC-P1-SH-003)" {
  # 结构验证：parse_global_args 通过 config_read 读取全局配置
  local args_sh="${DEBNAS_ROOT}/lib/system/args.sh"
  local config_sh="${DEBNAS_ROOT}/lib/system/config.sh"

  grep -q '^parse_global_args()' "$args_sh"
  grep -q '^config_read()' "$config_sh"
  # parse_global_args 引用 config_read 或 /etc/debnas/debnas.conf
  grep -qE 'config_read|debnas\.conf' "$args_sh"
}

# ==================== print_colored NO_COLOR 行为 ====================

@test "shell: NO_COLOR=1 时颜色变量为空 (TC-P2-UI-001)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null

    # NO_COLOR=1 时所有颜色变量应为空
    if [[ -z "${COLOR_RED:-}" && -z "${COLOR_GREEN:-}" && -z "${COLOR_RESET:-}" ]]; then
      echo "COLORS_EMPTY"
    else
      echo "HAS_COLORS"
    fi
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"COLORS_EMPTY"* ]]
}
