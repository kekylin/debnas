#!/usr/bin/env bats
# 测试: 恢复/清理/信号处理验证 (TC-P1-REC-001~004, TC-P2-REC-005)
# Mock 策略: 结构 grep + PATH Injection

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"

# ==================== TC-P1-REC-001: Ctrl+C → state_mark_success 未被调用 ====================

@test "recovery: run_report 仅在 exit_code=0 时调用 state_mark_success (TC-P1-REC-001)" {
  local runner="${DEBNAS_ROOT}/bin/module-runner.sh"
  # state_mark_success 被调用在 "$exit_code" -eq 0 分支内
  grep -A15 'exit_code.*-eq 0' "$runner" | grep -q 'state_mark_success'
}

# ==================== TC-P1-REC-002: trap 清理临时文件 ====================

@test "recovery: tempfile.sh 注册 EXIT/INT/TERM trap (TC-P1-REC-002)" {
  local tempfile_sh="${DEBNAS_ROOT}/lib/system/tempfile.sh"

  grep -A10 '^register_temp_cleanup()' "$tempfile_sh" | grep -q 'trap.*EXIT'
  grep -A10 '^register_temp_cleanup()' "$tempfile_sh" | grep -q 'trap.*INT'
  grep -A10 '^register_temp_cleanup()' "$tempfile_sh" | grep -q 'trap.*TERM'
}

@test "recovery: cleanup_temp_files 函数删除临时目录" {
  local tempfile_sh="${DEBNAS_ROOT}/lib/system/tempfile.sh"

  grep -q '^cleanup_temp_files()' "$tempfile_sh"
  grep -A5 '^cleanup_temp_files()' "$tempfile_sh" | grep -q 'rm'
}

@test "recovery: _debnas_cleanup_on_signal 处理 INT TERM 信号" {
  local tempfile_sh="${DEBNAS_ROOT}/lib/system/tempfile.sh"

  grep -q '^_debnas_cleanup_on_signal()' "$tempfile_sh"
  grep -A5 '^_debnas_cleanup_on_signal()' "$tempfile_sh" | grep -q 'cleanup_temp_files'
}

# ==================== TC-P1-REC-003: install.sh EXIT trap 清理 tarball ====================

@test "recovery: install.sh EXIT trap 清理 tarball (TC-P1-REC-003)" {
  local install_sh="${DEBNAS_ROOT}/install.sh"

  grep -q 'trap.*EXIT' "$install_sh"
  grep -q 'trap - EXIT' "$install_sh"
}

# ==================== TC-P1-REC-004: install.sh 部分清理逻辑 ====================

@test "recovery: install.sh 包含 _install_tmpdir 清理逻辑 (TC-P1-REC-004)" {
  local install_sh="${DEBNAS_ROOT}/install.sh"

  grep -q '_install_tmpdir' "$install_sh"
}

# ==================== TC-P2-REC-005: apt_wait_for_lock 超时处理 ====================

@test "recovery: apt_wait_for_lock 超时调用方正确处理 (TC-P2-REC-005)" {
  local apt_sh="${DEBNAS_ROOT}/lib/system/apt.sh"

  grep -q '^apt_wait_for_lock()' "$apt_sh"
  grep -A5 '^apt_update_safe()' "$apt_sh" | grep -q 'apt_wait_for_lock'
}

# ==================== sentinel 文件跨进程去重 ====================

@test "recovery: _debnas_cleanup_on_exit 使用 sentinel 文件去重" {
  local tempfile_sh="${DEBNAS_ROOT}/lib/system/tempfile.sh"

  grep -q '^_debnas_cleanup_on_exit()' "$tempfile_sh"
  grep -qE '_DEBNAS_SIGNAL_SENTINEL' "$tempfile_sh"
}

# ==================== mark_normal_exit ====================

@test "recovery: mark_normal_exit 设置 _DEBNAS_NORMAL_EXIT=1" {
  local tempfile_sh="${DEBNAS_ROOT}/lib/system/tempfile.sh"

  grep -q '^mark_normal_exit()' "$tempfile_sh"
  grep -A2 '^mark_normal_exit()' "$tempfile_sh" | grep -q '_DEBNAS_NORMAL_EXIT=1'
}
