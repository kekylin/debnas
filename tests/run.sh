#!/usr/bin/env bash
# DebNAS 测试入口
# 用法: bash tests/run.sh [syntax|static|unit|integration|all]
#
# 测试分层:
#   syntax  — bash -n 语法检查（全部 .sh 文件）
#   static  — ShellCheck 静态分析（error 级别）
#   unit    — BATS 单元测试
#   all     — 顺序执行 syntax + static + unit
#
# VM 集成测试（第 5 层）请参见 tests/test-plan.md，通过 SSH 手动执行。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TYPE="${1:-all}"

# 项目根目录（tests/ 的上级目录），传递给 common-setup.bash
export DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# 统计变量
_PASSED=0
_FAILED=0

# ==================== 语法检查 ====================

run_syntax_check() {
  echo "=== 第 1 层：语法检查 (bash -n) ==="
  local errors=0
  while IFS= read -r -d '' f; do
    # 跳过 tests/ 目录中的文件（BATS 测试文件语法由 BATS 自身保证）
    if [[ "$f" == */tests/* ]]; then
      continue
    fi
    if ! bash -n "$f" 2>&1; then
      ((errors++)) || true
    fi
  done < <(find "${DEBNAS_ROOT}" -name '*.sh' -not -path '*/tests/*' -not -path '*/.claude/*' -print0)

  # bin/debnas 无 .sh 扩展名，需单独检查
  if [[ -f "${DEBNAS_ROOT}/bin/debnas" ]]; then
    if ! bash -n "${DEBNAS_ROOT}/bin/debnas" 2>&1; then
      ((errors++)) || true
    fi
  fi

  if (( errors > 0 )); then
    echo "[FAIL] 语法检查: ${errors} 个文件有错误"
    return 1
  fi
  echo "[PASS] 语法检查通过"
  return 0
}

# ==================== 静态分析 ====================

run_static_analysis() {
  echo "=== 第 2 层：ShellCheck 静态分析 ==="

  if ! command -v shellcheck &>/dev/null; then
    echo "[SKIP] shellcheck 未安装，跳过静态分析"
    echo "  安装方法: sudo apt install shellcheck"
    return 0
  fi

  local errors=0
  # lib/**/*.sh 需要 globstar 才会递归并包含 lib/*.sh（否则只匹配 lib/*/*.sh，漏掉 bootstrap*.sh）
  shopt -s globstar

  # ShellCheck lib/ 目录
  if ! shellcheck --severity=error -x "${DEBNAS_ROOT}"/lib/**/*.sh 2>&1; then
    ((errors++)) || true
  fi

  # ShellCheck bin/ 目录（含无扩展名的 bin/debnas）与 install.sh、tools/
  if ! shellcheck --severity=error -x "${DEBNAS_ROOT}"/bin/*.sh "${DEBNAS_ROOT}"/bin/debnas "${DEBNAS_ROOT}"/install.sh "${DEBNAS_ROOT}"/tools/*.sh 2>&1; then
    ((errors++)) || true
  fi

  # ShellCheck modules/ 目录（单文件模块）
  if ! shellcheck --severity=error -x "${DEBNAS_ROOT}"/modules/*.sh 2>&1; then
    ((errors++)) || true
  fi

  # ShellCheck modules/ 子目录（多文件模块）
  while IFS= read -r -d '' f; do
    if ! shellcheck --severity=error -x "$f" 2>&1; then
      ((errors++)) || true
    fi
  done < <(find "${DEBNAS_ROOT}"/modules -mindepth 2 -name '*.sh' -print0)

  if (( errors > 0 )); then
    echo "[FAIL] ShellCheck: ${errors} 处 error 级别问题"
    return 1
  fi
  echo "[PASS] ShellCheck 通过"
  return 0
}

# ==================== 单元测试 ====================

run_unit_tests() {
  echo "=== 第 3 层：BATS 单元测试 ==="

  if ! command -v bats &>/dev/null; then
    echo "[FAIL] bats 未安装，无法运行单元测试"
    echo "  安装方法: sudo apt install bats"
    return 1
  fi

  # 捕获输出以检测真实失败（忽略 "Executed X instead of expected Y" 告警）
  local bats_output
  local bats_rc=0
  bats_output=$(bats --recursive "${SCRIPT_DIR}/unit/" 2>&1) || bats_rc=$?
  echo "$bats_output"

  # 检查是否有 not ok 行（真实测试失败）
  # 不能用 echo | grep -q：pipefail 下 grep 提前退出使 echo 收到 SIGPIPE，管道返回 141，失败被漏报
  if [[ $bats_rc -ne 0 ]] || grep -q '^not ok ' <<<"$bats_output"; then
    return 1
  fi
  return 0
}

# ==================== 入口路由 ====================

case "$TEST_TYPE" in
  syntax)
    run_syntax_check || exit 1
    ;;
  static)
    run_static_analysis || exit 1
    ;;
  unit)
    run_unit_tests || exit 1
    ;;
  integration)
    echo "=== 第 5 层：集成测试 (BATS) ==="
    if ! command -v bats &>/dev/null; then
      echo "[FAIL] bats 未安装，无法运行集成测试"
      echo "  安装方法: sudo apt install bats"
      exit 1
    fi
    bats_rc=0
    bats_output=$(bats --recursive "${SCRIPT_DIR}/integration/" 2>&1) || bats_rc=$?
    echo "$bats_output"
    if [[ $bats_rc -ne 0 ]] || grep -q '^not ok ' <<<"$bats_output"; then
      exit 1
    fi
    ;;
  all)
    echo "╔══════════════════════════════════════════╗"
    echo "║       DebNAS 自动化测试（第 1-3 层）     ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    run_syntax_check || exit 1
    echo ""
    run_static_analysis || exit 1
    echo ""
    run_unit_tests || exit 1
    echo ""
    echo "=== 第 4 层：冒烟测试（模块元数据检查）==="
    echo "请执行 tests/check.sh 进行完整质量门禁检查"
    echo ""
    echo "=== 第 5 层：集成测试（模块注册/依赖解析/执行流程）==="
    echo "请执行 bash tests/run.sh integration"
    echo ""
    echo "=== 第 6 层：VM 集成测试 ==="
    echo "请参见 tests/test-plan.md"
    ;;
  *)
    echo "用法: bash tests/run.sh [syntax|static|unit|integration|all]"
    echo ""
    echo "  syntax      — bash -n 语法检查（全部 .sh 文件）"
    echo "  static      — ShellCheck 静态分析（error 级别）"
    echo "  unit        — BATS 单元测试"
    echo "  integration — BATS 集成测试"
    echo "  all         — 顺序执行 syntax + static + unit"
    echo ""
    echo "VM 集成测试（第 6 层）请参见 tests/test-plan.md"
    exit 1
    ;;
esac
