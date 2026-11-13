#!/usr/bin/env bash
# tools/check-docs.sh — 比对维护者文档中的计数与仓库实际值（只读）
#
# 用法:
#   bash tools/check-docs.sh
#
# 说明:
#   docs/ 按项目约定不入库（仅维护者本地存在）。未找到 docs/ 时输出 [SKIP]
#   并以 0 退出，可安全用于 CI 或发布前检查。
#   可用 DEBNAS_DOCS_DIR 指向另一份文档目录（测试用）。
#
# 返回:
#   0 — 计数一致，或 docs/ 不存在而跳过
#   1 — 文档计数与仓库实际值不一致

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS="${DEBNAS_DOCS_DIR:-${ROOT}/docs}"

if [[ ! -d "$DOCS" ]]; then
  echo "[SKIP] 未找到 ${DOCS}（docs/ 按项目约定不入库）"
  exit 0
fi

_fail=0

# 比较一项：$1 标签，$2 实际值，$3 文档值（空表示未找到条目）
_expect() {
  local label="$1" actual="$2" expected="$3"
  if [[ -z "$expected" ]]; then
    echo "[WARN] ${label}: 文档条目未找到，跳过"
    return 0
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "[OK]   ${label}: ${actual}"
  else
    echo "[DIFF] ${label}: 实际 ${actual}，文档 ${expected}"
    _fail=1
  fi
}

_count() { wc -l | tr -d ' '; }

_modules=$(( $(find "${ROOT}/modules" -maxdepth 1 -name '*.sh' | _count) \
  + $(find "${ROOT}/modules" -mindepth 2 -maxdepth 2 -name 'module.sh' | _count) ))
_lib=$(find "${ROOT}/lib" -name '*.sh' | _count)
_bats_files=$(find "${ROOT}/tests" -name '*.bats' | _count)
_bats_tests=$(grep -rh '^@test' "${ROOT}/tests" --include='*.bats' | _count)
_int_files=$(find "${ROOT}/tests/integration" -name '*.bats' | _count)
_int_tests=$(grep -rh '^@test' "${ROOT}/tests/integration" --include='*.bats' | _count)

_overview_num() {
  grep -m1 "^| $1 |" "${DOCS}/PROJECT_OVERVIEW.md" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1 || true
}
_debt_count() {
  grep -m1 -oE '[0-9]+ 个 BATS 文件、[0-9]+ 个用例' "${DOCS}/TECH_DEBT.md" 2>/dev/null \
    | grep -oE '[0-9]+' | sed -n "$1p" || true
}
_int_count() {
  grep -m1 'tests/integration/' "${DOCS}/TESTING_GUIDE.md" 2>/dev/null \
    | grep -oE '[0-9]+' | sed -n "$1p" || true
}
_arch_modules() {
  grep -m1 '功能模块（' "${DOCS}/ARCHITECTURE.md" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1 || true
}

_expect "PROJECT_OVERVIEW 功能模块" "$_modules" "$(_overview_num '功能模块')"
_expect "PROJECT_OVERVIEW 公共库文件" "$_lib" "$(_overview_num '公共库文件')"
_expect "PROJECT_OVERVIEW BATS 测试文件" "$_bats_files" "$(_overview_num 'BATS 测试文件')"
_expect "ARCHITECTURE 功能模块" "$_modules" "$(_arch_modules)"
_expect "TECH_DEBT BATS 文件" "$_bats_files" "$(_debt_count 1)"
_expect "TECH_DEBT BATS 用例" "$_bats_tests" "$(_debt_count 2)"
_expect "TESTING_GUIDE 集成测试文件" "$_int_files" "$(_int_count 1)"
_expect "TESTING_GUIDE 集成测试用例" "$_int_tests" "$(_int_count 2)"

if (( _fail )); then
  echo "[FAIL] 文档计数与实现不一致"
  exit 1
fi
echo "[PASS] 文档计数与实现一致"
