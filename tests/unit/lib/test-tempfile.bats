#!/usr/bin/env bats
# 测试: lib/system/tempfile.sh — 临时文件集中管理

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 使用临时目录作为 DEBNAS_TMP_BASE
  TEST_TMP_BASE="$BATS_TMPDIR/debnas-tmp"
  export DEBNAS_TMP_BASE="$TEST_TMP_BASE"

  # 创建 mock 命令目录（仅用于需要 mock 的场景）
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"

  # 默认不 override PATH — 使用真实命令
  # 仅在需要模拟失败时向 MOCK_BIN 添加 mock 并 prepend PATH

  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"

  # 重置全局状态
  _DEBNAS_CLEANUP_REGISTERED=0
  _DEBNAS_NORMAL_EXIT=0
  rm -f /tmp/.debnas_signal_handled
}

teardown() {
  rm -rf "$MOCK_BIN" "$TEST_TMP_BASE"
  rm -f /tmp/.debnas_signal_handled
}

# ==================== init_temp_dir 测试 ====================

@test "init_temp_dir: 目录不存在时创建" {
  init_temp_dir
  [[ -d "$DEBNAS_TMP_BASE" ]]
}

@test "init_temp_dir: 目录已存在时幂等" {
  mkdir -p "$DEBNAS_TMP_BASE"
  init_temp_dir
  [[ -d "$DEBNAS_TMP_BASE" ]]
}

@test "init_temp_dir: 基目录为符号链接时拒绝使用（防抢占）" {
  local target="$BATS_TMPDIR/debnas-tmp-target"
  mkdir -p "$target"
  ln -s "$target" "$DEBNAS_TMP_BASE"
  run init_temp_dir
  [[ "$status" -ne 0 ]]
  [[ ! -e "$target/pid-$$" ]]
  rm -f "$DEBNAS_TMP_BASE"
  rmdir "$target"
}

# 注：init_temp_dir 中 mkdir 失败路径因 DEBNAS_TMP_BASE 为 readonly 无法在单元测试中覆盖，
# 该场景通过 VM 测试中模拟磁盘写保护来验证。

# ==================== create_temp_file 测试 ====================

@test "create_temp_file: 创建临时文件成功" {
  result=$(create_temp_file "test-prefix")
  [[ -f "$result" ]]
  [[ "$result" == ${_DEBNAS_PID_DIR}/* ]]
}

@test "create_temp_file: 文件位于 PID 隔离目录" {
  # 验证文件创建在进程专属的 PID 子目录下（而非直接位于基目录）
  # 使用临时文件捕获输出（避免 $() 子 shell 行为差异）
  local outfile="$BATS_TMPDIR/temp-result.txt"
  create_temp_file "track-me" > "$outfile"
  local result
  result=$(cat "$outfile")

  [[ -f "$result" ]]
  [[ "$result" == ${_DEBNAS_PID_DIR}/* ]]
}

@test "create_temp_file: 支持自定义后缀" {
  result=$(create_temp_file "prefix" ".log")
  [[ "$result" == *.log ]]
}

@test "create_temp_file / create_temp_dir: 无前缀报错 — 参数化" {
  local funcs=("create_temp_file" "create_temp_dir")
  for func in "${funcs[@]}"; do
    run "$func"
    [[ "$status" -ne 0 ]]
  done
}

# ==================== create_temp_dir 测试 ====================

@test "create_temp_dir: 创建临时目录成功" {
  result=$(create_temp_dir "test-dir")
  [[ -d "$result" ]]
  [[ "$result" == ${_DEBNAS_PID_DIR}/* ]]
}

@test "create_temp_dir: 目录位于 PID 隔离目录" {
  local outfile="$BATS_TMPDIR/dir-result.txt"
  create_temp_dir "track-dir" > "$outfile"
  local result
  result=$(cat "$outfile")

  [[ -d "$result" ]]
  [[ "$result" == ${_DEBNAS_PID_DIR}/* ]]
}

# ==================== cleanup_temp_files 测试 ====================

@test "cleanup_temp_files: 清理 PID 子目录及内容" {
  init_temp_dir
  local fake_file="${_DEBNAS_PID_DIR}/fake-file.tmp"
  local fake_dir="${_DEBNAS_PID_DIR}/fake-subdir"
  touch "$fake_file"
  mkdir -p "$fake_dir"

  # 验证文件存在
  [[ -f "$fake_file" ]]
  [[ -d "$fake_dir" ]]
  [[ -d "$_DEBNAS_PID_DIR" ]]

  cleanup_temp_files

  # PID 子目录及其下所有内容被移除
  [[ ! -f "$fake_file" ]]
  [[ ! -d "$fake_dir" ]]
  [[ ! -d "$_DEBNAS_PID_DIR" ]]
}

@test "cleanup_temp_files: PID 目录不存在时不报错" {
  # 清理之前删除 PID 目录，模拟未创建任何临时文件的场景
  rm -rf "$_DEBNAS_PID_DIR" 2>/dev/null || true
  cleanup_temp_files
  # 函数应正常返回（不报错）
}

@test "cleanup_temp_files: 基目录为空时移除" {
  mkdir -p "$DEBNAS_TMP_BASE"
  # 注意：基目录可能因为 PID 子目录存在而不为空，
  # 先确保 PID 子目录不存在
  rm -rf "$_DEBNAS_PID_DIR" 2>/dev/null || true
  cleanup_temp_files
  [[ ! -d "$DEBNAS_TMP_BASE" ]]
}

# ==================== register_temp_cleanup 测试 ====================

@test "register_temp_cleanup: 首次注册设置标志" {
  register_temp_cleanup
  [[ $_DEBNAS_CLEANUP_REGISTERED -eq 1 ]]
}

@test "register_temp_cleanup: 重复调用幂等" {
  register_temp_cleanup
  register_temp_cleanup
  [[ $_DEBNAS_CLEANUP_REGISTERED -eq 1 ]]
}

# ==================== mark_normal_exit 测试 ====================

@test "mark_normal_exit: 设置退出标志" {
  mark_normal_exit
  [[ $_DEBNAS_NORMAL_EXIT -eq 1 ]]
}

# ==================== _debnas_cleanup_on_signal 测试 ====================

@test "_debnas_cleanup_on_signal: 清理并写入 sentinel 文件" {
  init_temp_dir
  local fake_file="${_DEBNAS_PID_DIR}/sig-test.tmp"
  touch "$fake_file"

  # 在子 shell 中执行（exit 1 不会终止 BATS）
  ( _debnas_cleanup_on_signal ) || true
  [[ -f "$_DEBNAS_SIGNAL_SENTINEL" ]]
  [[ ! -f "$fake_file" ]]
  [[ ! -d "$_DEBNAS_PID_DIR" ]]
}

@test "_debnas_cleanup_on_signal: sentinel 已存在时跳过提示" {
  mkdir -p "$DEBNAS_TMP_BASE"
  # 预先创建 sentinel
  touch "$_DEBNAS_SIGNAL_SENTINEL"

  ( _debnas_cleanup_on_signal ) || true
  # 不应崩溃，sentinel 仍存在
  [[ -f "$_DEBNAS_SIGNAL_SENTINEL" ]]
}

# ==================== 审计修复：root 用 /run/debnas（0700） ====================

@test "tempfile: root 默认基目录为 /run/debnas（0700），非 root 仍为 /tmp/debnas" {
  if [[ "$EUID" -ne 0 ]]; then
    run env -u DEBNAS_TMP_BASE bash -c 'source "$1/lib/system/tempfile.sh"; echo "$DEBNAS_TMP_BASE $_DEBNAS_TMP_BASE_MODE"' _ "$DEBNAS_ROOT"
    [[ "$output" == "/tmp/debnas 755" ]]
    skip "root 分支需以 root 运行"
  fi
  run env -u DEBNAS_TMP_BASE bash -c 'source "$1/lib/system/tempfile.sh"; echo "$DEBNAS_TMP_BASE"
    init_temp_dir && stat -c "%a %U" "$DEBNAS_TMP_BASE"; cleanup_temp_files' _ "$DEBNAS_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == "/run/debnas" && "${lines[1]}" == "700 root" ]]
  if command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1 \
     && runuser -u nobody -- test -r "$DEBNAS_ROOT/lib/system/tempfile.sh"; then
    run runuser -u nobody -- env -u DEBNAS_TMP_BASE bash -c 'source "$1/lib/system/tempfile.sh"; echo "$DEBNAS_TMP_BASE $_DEBNAS_TMP_BASE_MODE"' _ "$DEBNAS_ROOT"
    [[ "$output" == "/tmp/debnas 755" ]]
  fi
}

@test "debnas_locked: 串行化同名锁、可重入、返回命令退出码" {
  run debnas_locked t1 bash -c 'exit 7'
  [[ "$status" -eq 7 ]]
  _inner() { debnas_locked t1 echo inner-ok; }
  run debnas_locked t1 _inner
  [[ "$status" -eq 0 && "$output" == "inner-ok" ]]
  local out="$BATS_TMPDIR/lock-order"
  rm -f "$out"
  ( debnas_locked t2 bash -c 'echo a1 >> "$1"; sleep 0.5; echo a2 >> "$1"' _ "$out" ) &
  sleep 0.1
  debnas_locked t2 bash -c 'echo b >> "$1"' _ "$out"
  wait
  [[ "$(tr '\n' ' ' < "$out")" == "a1 a2 b " ]]
}

@test "debnas_locked: 之后的语句继续执行、stderr 不被吞、返回码透传、嵌套不死锁" {
  run bash -c 'source "$1/lib/system/tempfile.sh"
    f() { echo "in-f"; return 3; }
    g() { debnas_locked x f; }
    rc=0; debnas_locked x g || rc=$?
    echo "after rc=$rc"
    echo "stderr-still-visible" >&2
    debnas_locked y true && echo "second-ok"' _ "$DEBNAS_ROOT"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"in-f"*"after rc=3"*"stderr-still-visible"*"second-ok"* ]]
}

@test "lock_acquire: --nonblock 锁被占用时返回 1" {
  command -v flock >/dev/null 2>&1 || skip "需要 flock"
  local fd1="" rc=0
  lock_acquire t3 fd1 --required || rc=$?
  [[ "$rc" -eq 0 && -n "$fd1" ]]
  run lock_acquire t3 fd2 --nonblock --required
  [[ "$status" -ne 0 ]]
  lock_release "$fd1"
}

@test "lock_acquire: --timeout 等待超时后返回 1" {
  command -v flock >/dev/null 2>&1 || skip "需要 flock"
  local fd1="" rc=0
  lock_acquire t4 fd1 --required || rc=$?
  [[ "$rc" -eq 0 && -n "$fd1" ]]
  run lock_acquire t4 fd2 --timeout 1 --required
  [[ "$status" -ne 0 ]]
  lock_release "$fd1"
}

@test "lock_acquire: 拒绝符号链接锁文件" {
  mkdir -p "$DEBNAS_TMP_BASE"
  ln -sfn /tmp/debnas-lock-target "$DEBNAS_TMP_BASE/evil.lock" 2>/dev/null || skip "当前环境不支持符号链接"
  run lock_acquire evil fd --required
  [[ "$status" -ne 0 ]]
  rm -f "$DEBNAS_TMP_BASE/evil.lock"
}

@test "module-probe: _module_probe_wait 打开睡眠管道后 stderr 仍可见" {
  run bash -c 'source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"
    source "$1/lib/system/utils.sh"; source "$1/lib/system/module-registry.sh"; source "$1/lib/system/module-probe.sh"
    sleep 0.05 & _module_probe_wait $! 2 || true
    echo "stderr-still-visible" >&2' _ "$DEBNAS_ROOT"
  [[ "$output" == *"stderr-still-visible"* ]]
}
