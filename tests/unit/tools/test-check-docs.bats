#!/usr/bin/env bats
# 测试: tools/check-docs.sh — 文档计数与实现比对（只读）

load '../../helpers/common-setup'

TOOL="${DEBNAS_ROOT}/tools/check-docs.sh"

# 在临时目录生成一份最小文档，参数为四项计数的目标值
_mk_docs() {
  local dir="$1" modules="$2" lib="$3" bats_files="$4" bats_tests="$5"
  local int_files="$6" int_tests="$7"
  mkdir -p "$dir"
  cat > "${dir}/PROJECT_OVERVIEW.md" <<EOF
| 功能模块 | ${modules} 个 |
| 公共库文件 | ${lib} 个（core ×3 + system ×20 + ui ×9 + root ×2） |
| BATS 测试文件 | ${bats_files} 个（unit ×66 + integration ×15） |
EOF
  cat > "${dir}/ARCHITECTURE.md" <<EOF
│ 功能模块（${modules} 个）
EOF
  cat > "${dir}/TECH_DEBT.md" <<EOF
- **问题**：当前有 ${bats_files} 个 BATS 文件、${bats_tests} 个用例
EOF
  cat > "${dir}/TESTING_GUIDE.md" <<EOF
- \`tests/integration/\`：${int_files} 个文件、${int_tests} 用例
EOF
}

# 输出仓库实际计数，依次为 modules lib bats_files bats_tests int_files int_tests
_actual() {
  local modules lib bats_files bats_tests int_files int_tests
  modules=$(( $(find "${DEBNAS_ROOT}/modules" -maxdepth 1 -name '*.sh' | wc -l) \
    + $(find "${DEBNAS_ROOT}/modules" -mindepth 2 -maxdepth 2 -name 'module.sh' | wc -l) ))
  lib=$(find "${DEBNAS_ROOT}/lib" -name '*.sh' | wc -l)
  bats_files=$(find "${DEBNAS_ROOT}/tests" -name '*.bats' | wc -l)
  bats_tests=$(grep -rh '^@test' "${DEBNAS_ROOT}/tests" --include='*.bats' | wc -l)
  int_files=$(find "${DEBNAS_ROOT}/tests/integration" -name '*.bats' | wc -l)
  int_tests=$(grep -rh '^@test' "${DEBNAS_ROOT}/tests/integration" --include='*.bats' | wc -l)
  echo "$((modules)) $((lib)) $((bats_files)) $((bats_tests)) $((int_files)) $((int_tests))"
}

@test "check-docs: 未找到 docs/ 时 SKIP 并返回 0" {
  run env DEBNAS_DOCS_DIR="${BATS_TEST_TMPDIR}/no-such-docs" bash "$TOOL"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[SKIP]"* ]]
}

@test "check-docs: 文档计数与仓库一致时 PASS" {
  local dir="${BATS_TEST_TMPDIR}/docs-ok"
  read -r m l bf bt inf int < <(_actual)
  _mk_docs "$dir" "$m" "$l" "$bf" "$bt" "$inf" "$int"
  run env DEBNAS_DOCS_DIR="$dir" bash "$TOOL"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[PASS]"* ]]
  [[ "$output" != *"[DIFF]"* ]]
}

@test "check-docs: 计数不一致时返回 1 并列出差异" {
  local dir="${BATS_TEST_TMPDIR}/docs-bad"
  read -r m l bf bt inf int < <(_actual)
  _mk_docs "$dir" "$((m + 1))" "$l" "$bf" "$((bt + 1))" "$inf" "$int"
  run env DEBNAS_DOCS_DIR="$dir" bash "$TOOL"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"[DIFF] PROJECT_OVERVIEW 功能模块"* ]]
  [[ "$output" == *"[DIFF] TECH_DEBT BATS 用例"* ]]
  [[ "$output" == *"[FAIL]"* ]]
}

@test "check-docs: 缺少某项文档条目时告警但不失败" {
  local dir="${BATS_TEST_TMPDIR}/docs-partial"
  mkdir -p "$dir"
  : > "${dir}/PROJECT_OVERVIEW.md"
  : > "${dir}/ARCHITECTURE.md"
  : > "${dir}/TECH_DEBT.md"
  : > "${dir}/TESTING_GUIDE.md"
  run env DEBNAS_DOCS_DIR="$dir" bash "$TOOL"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"[WARN]"* ]]
  [[ "$output" == *"[PASS]"* ]]
}
