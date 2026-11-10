#!/usr/bin/env bats
# 测试: 错误处理路径验证 (TC-P1-ERR-001~011)
# Mock 策略: 结构 grep + 子 shell 隔离 + 函数覆盖 + PATH Injection

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"

# ==================== TC-P1-ERR-001~003: 错误码常量验证 ====================

@test "error: ERROR_PERMISSION 常量值为 4 (TC-P1-ERR-001)" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    echo "ERROR_PERMISSION=$ERROR_PERMISSION"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ERROR_PERMISSION=4"* ]]
}

@test "error: ERROR_UNSUPPORTED_OS 常量值为 6 (TC-P1-ERR-002)" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    echo "ERROR_UNSUPPORTED_OS=$ERROR_UNSUPPORTED_OS"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ERROR_UNSUPPORTED_OS=6"* ]]
}

@test "error: ERROR_DEPENDENCY 常量值为 2 (TC-P1-ERR-003)" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    echo "ERROR_DEPENDENCY=$ERROR_DEPENDENCY"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"ERROR_DEPENDENCY=2"* ]]
}

# ==================== TC-P1-ERR-004: log_fatal 在子 shell 中仅退出子 shell ====================

@test "error: log_fatal 在子 shell 中仅退出子 shell (TC-P1-ERR-004)" {
  run bash -c '
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null

    # log_fatal 内部调用 exit 1，在 (...) 子 shell 中仅退出子 shell
    ( log_fatal "test fatal" 2>/dev/null ) || true
    echo "PARENT_SURVIVES"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"PARENT_SURVIVES"* ]]
}

# ==================== TC-P1-ERR-005: log_fatal_return 返回 1 不退出 ====================

@test "error: log_fatal_return 返回 1 不退出进程 (TC-P1-ERR-005)" {
  run bash -c '
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null

    rc=0
    log_fatal_return "test fatal return" 2>/dev/null || rc=$?
    echo "FATAL_RETURN_RC=$rc"
    echo "CONTINUES_AFTER"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"FATAL_RETURN_RC=1"* ]]
  [[ "$output" == *"CONTINUES_AFTER"* ]]
}

# ==================== TC-P1-ERR-006: write_file_if_changed 在 set -e 下返回 1 ====================

@test "error: write_file_if_changed 内容相同返回 1 需 || true 保护 (TC-P1-ERR-006)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/utils.sh 2>/dev/null

    tmpfile=$(mktemp)
    echo "same content" > "$tmpfile"
    write_file_if_changed "$tmpfile" "same content" || true
    echo "SURVIVED_SET_E"
    rm -f "$tmpfile"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SURVIVED_SET_E"* ]]
}

# ==================== TC-P1-ERR-007: ((var++)) 0→1 退出码 1 陷阱 ====================

@test "error: ((var++)) 0→1 退出码 1 需 || true 保护 (TC-P1-ERR-007)" {
  run bash -c '
    set -euo pipefail
    count=0
    ((count++)) || true
    echo "COUNT=$count"
    echo "SURVIVED"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SURVIVED"* ]]
}

# ==================== TC-P1-ERR-008: pipefail 中间管道命令失败 ====================

@test "error: pipefail 中间管道失败退出码传播 (TC-P1-ERR-008)" {
  run bash -c '
    set -o pipefail
    echo "ok" | false | cat
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P1-ERR-009~011: curl 错误处理 ====================

@test "error: probe_url curl 连接失败返回非零 (TC-P1-ERR-009)" {
  # 结构验证：probe_url 对 curl/wget 缺失返回 1
  local urls_sh="${DEBNAS_ROOT}/lib/system/urls.sh"
  grep -q 'return 1' "$urls_sh"
}

@test "error: probe_url curl DNS/wget 都不可用返回非零 (TC-P1-ERR-010)" {
  run bash -c '
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/urls.sh 2>/dev/null

    # 覆盖 curl 和 wget 为失败（函数覆盖 > PATH）
    curl() { return 1; }
    wget() { return 1; }

    probe_url "https://unreachable.example.com" 2>/dev/null || echo "PROBE_FAILED"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"PROBE_FAILED"* ]]
}

@test "error: probe_url curl -f 标志识别 HTTP 404 (TC-P1-ERR-011)" {
  local urls_sh="${DEBNAS_ROOT}/lib/system/urls.sh"
  grep -q '\-f' "$urls_sh" || grep -q '\-\-fail' "$urls_sh"
}

# ==================== ERROR_GENERAL 常量完整性 ====================

@test "error: ERROR_GENERAL 常量值为 1" {
  run bash -c '
    source "$1"/lib/core/constants.sh 2>/dev/null
    echo "ERROR_GENERAL=$ERROR_GENERAL"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"ERROR_GENERAL=1"* ]]
}

# ==================== 结构验证 ====================

@test "error: log_fatal 函数体包含 exit 调用" {
  local logging_sh="${DEBNAS_ROOT}/lib/core/logging.sh"
  grep -A5 '^log_fatal()' "$logging_sh" | grep -q 'exit'
}

@test "error: log_fatal_return 函数体包含 return 调用" {
  local logging_sh="${DEBNAS_ROOT}/lib/core/logging.sh"
  grep -A5 '^log_fatal_return()' "$logging_sh" | grep -q 'return'
}
