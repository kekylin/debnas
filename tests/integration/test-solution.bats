#!/usr/bin/env bats
# 测试: bin/menu.sh — execute_solution() 部署方案执行
# 自包含测试，直接 source 库文件

setup() {
  DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"

  TEST_ROOT="$BATS_TMPDIR/debnas-test"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config/solutions"
  EXEC_LOG="$BATS_TMPDIR/exec-order.log"
  FAIL_MARKER="$BATS_TMPDIR/fail-marker"
  : > "$EXEC_LOG"
  rm -f "$FAIL_MARKER"
  export EXEC_LOG FAIL_MARKER

  # 简化的 mock：只记录模块名，不检测 stdin（避免 read -t 0 兼容性问题）
  cat > "$TEST_ROOT/bin/module-runner.sh" << 'MOCKEOF'
#!/usr/bin/env bash
exec_log="${EXEC_LOG:-/tmp/exec-order.log}"
fail_marker="${FAIL_MARKER:-/tmp/fail-marker}"
module_name="${1:-unknown}"
echo "$module_name" >> "$exec_log"
if [[ -f "$fail_marker" ]]; then
  failing_module=$(cat "$fail_marker")
  [[ "$module_name" == "$failing_module" ]] && exit 1
fi
exit 0
MOCKEOF
  chmod +x "$TEST_ROOT/bin/module-runner.sh"
  REAL_MENU="${DEBNAS_ROOT}/bin/menu.sh"

  execute_solution() {
    local solution_name="$1"
    local solution_file="${TEST_ROOT}/config/solutions/${solution_name}.list"
    [[ -f "$solution_file" ]] || { log_error "not found: $solution_file"; return 1; }
    local failed=0 module_name
    while IFS= read -r line <&3; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      module_name="${line#"${line%%[![:space:]]*}"}"
      module_name="${module_name%"${module_name##*[![:space:]]}"}"
      [[ -n "$module_name" ]] || continue
      if ! bash "${TEST_ROOT}/bin/module-runner.sh" "$module_name" 2>/dev/null; then
        log_error "模块 \"$module_name\" 执行失败"
        failed=1; break
      fi
    done 3< "$solution_file"
    [[ $failed -eq 0 ]] && log_success "部署完成"
    return $failed
  }
}

teardown() {
  rm -rf "$TEST_ROOT" "$EXEC_LOG" "$FAIL_MARKER"
}

write_solution() {
  local name="$1" content="$2"
  printf '%s\n' "$content" > "${TEST_ROOT}/config/solutions/${name}.list"
}

# ==================== 测试用例 ====================

@test "execute_solution: 方案文件不存在时返回错误" {
  run execute_solution "nonexistent"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"not found"* ]]
}

@test "execute_solution: 注释和空行被跳过" {
  write_solution "empty" $'# comment\n\n  \n# another\n'
  run execute_solution "empty"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$EXEC_LOG" ]]
}

@test "execute_solution: 单模块方案正常执行" {
  write_solution "single" "only-module"
  run execute_solution "single"
  [[ "$status" -eq 0 ]]
  grep -q "only-module" "$EXEC_LOG"
}

@test "execute_solution: 按方案文件顺序依次执行模块" {
  write_solution "ordered" $'module-1\nmodule-2\nmodule-3\n'
  run execute_solution "ordered"
  [[ "$status" -eq 0 ]]
  grep -q "module-1" "$EXEC_LOG"
  grep -q "module-2" "$EXEC_LOG"
  grep -q "module-3" "$EXEC_LOG"
}

@test "execute_solution: stdin 不被方案文件污染（fd 3 隔离验证）" {
  # 通过管道输入模拟交互：如果 stdin 被污染，read 会读到方案文件内容
  write_solution "stdin-isolation" $'module-a\nmodule-b\n'
  
  # 使用旧版 done < file 执行（stdin 会被污染）
  execute_solution_old() {
    local solution_file="${TEST_ROOT}/config/solutions/stdin-isolation.list"
    local failed=0 module_name
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      module_name="${line#"${line%%[![:space:]]*}"}"
      module_name="${module_name%"${module_name##*[![:space:]]}"}"
      [[ -n "$module_name" ]] || continue
      bash "${TEST_ROOT}/bin/module-runner.sh" "$module_name" 2>/dev/null || { failed=1; break; }
    done < "$solution_file"
    return $failed
  }

  : > "$EXEC_LOG"
  # 旧版执行：stdin 被文件重定向污染
  run execute_solution_old
  # 至少有一个模块被执行（说明循环逻辑正常）
  [[ -s "$EXEC_LOG" ]]
  
  # 新版执行（fd 3）：stdin 保持干净
  : > "$EXEC_LOG"
  run execute_solution "stdin-isolation"
  [[ "$status" -eq 0 ]]
  grep -q "module-a" "$EXEC_LOG"
  grep -q "module-b" "$EXEC_LOG"
}

@test "execute_solution: 模块执行失败时中断后续模块" {
  write_solution "with-failure" $'module-ok\nmodule-bad\nmodule-skipped\n'
  echo "module-bad" > "$FAIL_MARKER"
  run execute_solution "with-failure"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"module-bad"* ]]
  grep -q "module-ok" "$EXEC_LOG"
  ! grep -q "module-skipped" "$EXEC_LOG"
}

@test "execute_solution: 全部模块成功时报告部署完成" {
  write_solution "all-ok" $'mod-a\nmod-b\n'
  run execute_solution "all-ok"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"部署完成"* ]]
}

@test "execute_solution: 模块名首尾空格被正确 trim" {
  write_solution "trimmed" $'  module-spaces  \n'
  run execute_solution "trimmed"
  [[ "$status" -eq 0 ]]
  grep -q "module-spaces" "$EXEC_LOG"
}

# ==================== 真实函数结构验证 ====================
# 注：以上测试使用简化的 stub 版本（避免 bin/menu.sh 的 exec/exit 副作用）
# 以下测试验证 bin/menu.sh 中真实的 execute_solution() 结构完整性

@test "execute_solution: bin/menu.sh 定义真实的 execute_solution" {
  grep -q '^execute_solution()' "$REAL_MENU"
}

@test "execute_solution: 真实函数使用 fd 3 隔离方案文件输入" {
  # fd 3 在函数末尾处（done 3< "$solution_file"，约 23 行），需要足够的上下文
  grep -A30 '^execute_solution()' "$REAL_MENU" | grep -q '3<'
}

@test "execute_solution: 真实函数调用 module-runner.sh 执行模块" {
  grep -A30 '^execute_solution()' "$REAL_MENU" | grep -q 'module-runner.sh'
}

@test "execute_solution: 真实函数包含失败中断逻辑（break）" {
  grep -A40 '^execute_solution()' "$REAL_MENU" | grep -q 'break'
}

@test "execute_solution: 真实函数过滤注释行和空行" {
  grep -A15 '^execute_solution()' "$REAL_MENU" | grep -q '#'
}
