#!/usr/bin/env bats
# 测试: lib/system/state.sh — 状态追踪

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/state.sh"
  # 使用临时目录测试
  TEST_STATE_DIR=$(mktemp -d)
  # 重定向状态目录到临时位置
  eval "DEBNAS_STATE_DIR=$TEST_STATE_DIR"
}

teardown() {
  rm -rf "$TEST_STATE_DIR"
}

@test "state_set 创建状态文件" {
  state_set "test-module" "key1" "value1"
  [ -f "${TEST_STATE_DIR}/test-module.state" ]
}

@test "state_get 读取已设置的值" {
  state_set "test-module" "version" "1.0.0"
  result=$(state_get "test-module" "version")
  [ "$result" = "1.0.0" ]
}

@test "state_get 不存在的键返回空" {
  state_set "test-module" "key1" "val1"
  run state_get "test-module" "nonexistent"
  [ "$status" -ne 0 ]
}

@test "state_set 更新已有值" {
  state_set "test-module" "key1" "old"
  state_set "test-module" "key1" "new"
  result=$(state_get "test-module" "key1")
  [ "$result" = "new" ]
}

@test "state_mark_success 设置成功状态" {
  state_mark_success "test-module" "2.0.0"
  result=$(state_get "test-module" "last_result")
  [ "$result" = "success" ]
}

@test "state_mark_success 记录版本号" {
  state_mark_success "test-module" "3.0.0"
  result=$(state_get "test-module" "installed_version")
  [ "$result" = "3.0.0" ]
}

@test "state_mark_fail 设置失败状态" {
  state_mark_fail "test-module" "timeout"
  result=$(state_get "test-module" "last_result")
  [ "$result" = "fail" ]
}

@test "state_is_installed 检测已安装模块" {
  state_mark_success "test-module"
  state_is_installed "test-module"
}

@test "state_is_installed 未安装返回 false" {
  run state_is_installed "nonexistent-module"
  [ "$status" -ne 0 ]
}

@test "state_clear 删除状态文件" {
  state_mark_success "test-module"
  state_clear "test-module"
  [ ! -f "${TEST_STATE_DIR}/test-module.state" ]
}

@test "state_mark_checkpoint 记录检查点" {
  state_mark_checkpoint "test-module" "step-3"
  result=$(state_get_checkpoint "test-module")
  [ "$result" = "step-3" ]
}

@test "state_set: 并发改写不同键持锁，不丢更新" {
  export DEBNAS_TMP_BASE="$BATS_TMPDIR/state-lock-base"
  rm -rf "$DEBNAS_TMP_BASE"
  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  local i
  for i in 1 2 3 4 5 6; do state_set "test-module" "k$i" "old"; done
  awk() { command awk "$@"; local rc=$?; sleep 0.2; return $rc; }
  for i in 1 2 3 4 5 6; do state_set "test-module" "k$i" "new$i" & done
  wait
  unset -f awk
  for i in 1 2 3 4 5 6; do
    [ "$(state_get "test-module" "k$i")" = "new$i" ]
  done
}

@test "module_mark_action: 写入非空内容（runner 按 -s 判定执行过）" {
  local m="$TEST_STATE_DIR/marker"
  : > "$m"
  DEBNAS_ACTION_MARKER="$m" module_mark_action
  [ -s "$m" ]
}
