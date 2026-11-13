#!/usr/bin/env bats
# 测试: lib/system/cron.sh — Cron 定时任务管理

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 使用共享 crontab Mock（定义在 helpers/common-setup.bash）
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  setup_crontab_mock
  source "${DEBNAS_ROOT}/lib/system/cron.sh"
}

teardown() {
  teardown_crontab_mock
}

# ==================== _cron_entry_marker 测试 ====================

@test "_cron_entry_marker: 生成正确的标记字符串" {
  result=$(_cron_entry_marker "test-module")
  [[ "$result" == "# DEBNAS-CRON: test-module" ]]
}

# ==================== _get_current_crontab 测试 ====================

@test "_get_current_crontab: 有内容时返回 crontab" {
  echo "0 * * * * /usr/bin/some-task" > "$CRON_STATE"
  result=$(_get_current_crontab)
  [[ "$result" == *"some-task"* ]]
}

@test "_get_current_crontab: 无 crontab 时返回空" {
  rm -f "$CRON_STATE"
  result=$(_get_current_crontab)
  [[ -z "$result" ]]
}

@test "_get_current_crontab: cron 明确报 no crontab 时按空处理并返回 0" {
  cat > "$MOCK_BIN/crontab" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then
  echo "no crontab for root" >&2
  exit 1
fi
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/crontab"
  run _get_current_crontab
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "_get_current_crontab: 其他读取错误返回 1" {
  cat > "$MOCK_BIN/crontab" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then
  echo "crontab: cannot open /var/spool/cron/crontabs/root: Permission denied" >&2
  exit 1
fi
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/crontab"
  run _get_current_crontab
  [[ "$status" -ne 0 ]]
}

@test "cron_register: 读取失败时拒绝写入，不覆盖用户 crontab" {
  echo "0 * * * * /usr/bin/user-job" > "$CRON_STATE"
  cat > "$MOCK_BIN/crontab" << 'INNEREOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then
  echo "crontab: Permission denied" >&2
  exit 1
fi
exit 0
INNEREOF
  chmod +x "$MOCK_BIN/crontab"
  run cron_register test-module "0 1 * * *"
  [[ "$status" -ne 0 ]]
  [[ "$(cat "$CRON_STATE")" == "0 * * * * /usr/bin/user-job" ]]
}

# ==================== _set_crontab 测试 ====================

@test "_set_crontab: 成功写入 crontab" {
  echo "*/5 * * * * /bin/true" | _set_crontab
  [[ "$(cat "$CRON_STATE")" == "*/5 * * * * /bin/true" ]]
}

# ==================== cron_register 测试 ====================

@test "cron_register: 正常注册定时任务" {
  run cron_register "test-module" "0 */6 * * *"
  [[ "$status" -eq 0 ]]
  # 验证 crontab 包含标记
  [[ "$(cat "$CRON_STATE")" == *"DEBNAS-CRON: test-module"* ]]
}

@test "cron_register: 5 字段 cron 表达式通过校验" {
  run cron_register "test-module" "0 */6 * * *"
  [[ "$status" -eq 0 ]]
}

@test "cron_register: 4 字段表达式被拒绝" {
  run cron_register "test-module" "0 */6 * *"
  [[ "$status" -ne 0 ]]
}

@test "cron_register: 6 字段表达式被拒绝" {
  run cron_register "test-module" "0 */6 * * * *"
  [[ "$status" -ne 0 ]]
}

@test "cron_register: 替换同一模块的已有条目" {
  # 先注册旧条目
  cron_register "test-module" "0 0 * * *"
  local first_content
  first_content=$(cat "$CRON_STATE")

  # 再注册新条目（不同 schedule）
  run cron_register "test-module" "30 */4 * * *"
  [[ "$status" -eq 0 ]]

  local second_content
  second_content=$(cat "$CRON_STATE")
  # 新内容不应包含旧 schedule
  [[ "$second_content" != "$first_content" ]]
  # 新内容应包含新 schedule
  [[ "$second_content" == *"30 */4 * * *"* ]]
  # 不应有重复标记
  local marker_count
  marker_count=$(grep -c "DEBNAS-CRON: test-module" "$CRON_STATE")
  [[ "$marker_count" -eq 1 ]]
}

@test "cron_register: 保留不相关的 crontab 条目" {
  # 预置一个不相关的 cron 条目
  echo "0 3 * * * /usr/bin/backup" > "$CRON_STATE"

  run cron_register "test-module" "0 */6 * * *"
  [[ "$status" -eq 0 ]]
  # 原有条目应保留
  [[ "$(cat "$CRON_STATE")" == *"/usr/bin/backup"* ]]
  # 新条目也应存在
  [[ "$(cat "$CRON_STATE")" == *"DEBNAS-CRON: test-module"* ]]
}

@test "cron_register_variant: 同一模块可注册额外条目" {
  cron_register "test-module" "0 1 * * 1"
  run cron_register_variant "test-module" "0 2 1 1 *" "--period 1y --email"
  [[ "$status" -eq 0 ]]
  local marker_count
  marker_count=$(grep -c "DEBNAS-CRON: test-module" "$CRON_STATE" || true)
  [[ "$marker_count" -eq 2 ]]
  [[ "$(cat "$CRON_STATE")" == *"--period 1y --email"* ]]
}

@test "cron_register_variant: 重复注册不产生重复条目" {
  cron_register "test-module" "0 1 * * 1"
  cron_register_variant "test-module" "0 2 1 1 *" "--period 1y --email"
  run cron_register_variant "test-module" "0 2 1 1 *" "--period 1y --email"
  [[ "$status" -eq 0 ]]
  local marker_count
  marker_count=$(grep -c "DEBNAS-CRON: test-module" "$CRON_STATE" || true)
  [[ "$marker_count" -eq 2 ]]
}

@test "cron_register_variant: cron_unregister 移除全部同模块条目" {
  cron_register "test-module" "0 1 * * 1"
  cron_register_variant "test-module" "0 2 1 1 *" "--period 1y --email"
  run cron_unregister "test-module"
  [[ "$status" -eq 0 ]]
  ! grep -q "DEBNAS-CRON: test-module" "$CRON_STATE" 2>/dev/null || true
}

# ==================== cron_unregister 测试 ====================

@test "cron_unregister: 存在时移除成功" {
  cron_register "test-module" "0 */6 * * *"
  run cron_unregister "test-module"
  [[ "$status" -eq 0 ]]
  # 标记应被移除
  ! grep -q "DEBNAS-CRON: test-module" "$CRON_STATE" 2>/dev/null || true
}

@test "cron_unregister: 不存在时幂等返回 0" {
  run cron_unregister "nonexistent-module"
  [[ "$status" -eq 0 ]]
}

@test "cron_unregister: 移除最后一条时清空整个 crontab" {
  cron_register "test-module" "0 */6 * * *"
  cron_unregister "test-module"
  # crontab 文件应被删除（crontab -r 被调用）
  [[ ! -f "$CRON_STATE" ]]
}

@test "cron_unregister: 保留其他 DebNAS 条目" {
  cron_register "module-a" "0 0 * * *"
  cron_register "module-b" "30 12 * * *"

  cron_unregister "module-a"
  # module-b 的标记应保留
  [[ "$(cat "$CRON_STATE")" == *"DEBNAS-CRON: module-b"* ]]
  # module-a 的标记应移除
  ! grep -q "DEBNAS-CRON: module-a" "$CRON_STATE" 2>/dev/null || true
}

# ==================== cron_list 测试 ====================

@test "cron_list: 无 crontab 时提示" {
  rm -f "$CRON_STATE"
  run cron_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"无"* ]]
}

@test "cron_list: 无 DebNAS 条目时提示" {
  echo "0 3 * * * /usr/bin/backup" > "$CRON_STATE"
  run cron_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"无"* ]]
}

@test "cron_list: 列出所有 DebNAS 条目" {
  cron_register "module-a" "0 0 * * *"
  cron_register "module-b" "30 */6 * * *"

  run cron_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"module-a"* ]]
  [[ "$output" == *"module-b"* ]]
}

# ==================== cron_is_registered 测试 ====================

@test "cron_is_registered: 已注册返回 0" {
  cron_register "test-module" "0 */6 * * *"
  cron_is_registered "test-module"
}

@test "cron_is_registered: 未注册返回 1" {
  run cron_is_registered "not-registered"
  [[ "$status" -ne 0 ]]
}

# ==================== cron_state 测试 ====================

@test "cron_state: 非 root（读不到 root crontab）返回 unknown" {
  _cron_can_read_root() { return 1; }
  echo "0 0 * * * DEBNAS_CRON_MODE=1 /usr/local/bin/debnas run test-module # DEBNAS-CRON: test-module" > "$CRON_STATE"
  run cron_state "test-module"
  [[ "$status" -eq 0 && "$output" == "unknown" ]]
}

@test "cron_state: 已注册 on / 未注册 off，同前缀模块不误判" {
  _cron_can_read_root() { return 0; }
  cron_register "test-module-ext" "0 0 * * *"
  run cron_state "test-module"
  [[ "$output" == "off" ]]
  cron_register "test-module" "0 */6 * * *"
  run cron_state "test-module"
  [[ "$status" -eq 0 && "$output" == "on" ]]
}

@test "cron_state: 变体条目按附加参数精确匹配" {
  _cron_can_read_root() { return 0; }
  cron_register_variant "test-module" "0 2 1 1 *" "--period 1y --email"
  run cron_state "test-module" "--period 1y --email"
  [[ "$output" == "on" ]]
  run cron_state "test-module" "--period 1m"
  [[ "$output" == "off" ]]
  run cron_state "test-module"
  [[ "$output" == "on" ]]
}

@test "cron_state: 系统无 crontab 命令时返回 off" {
  _cron_can_read_root() { return 0; }
  local nobin="${BATS_TMPDIR}/cron-nobin"
  mkdir -p "$nobin"
  PATH="$nobin" run cron_state "test-module"
  rm -rf "$nobin"
  [[ "$output" == "off" ]]
}

# ==================== 审计修复：表达式注入 / 变体保留 / 并发加锁 ====================

@test "cron_validate_schedule: 拒绝含换行/回车/% 的表达式（防 crontab 注入）" {
  run cron_validate_schedule $'0 0 * * *\n* * * * * touch /tmp/pwned'
  [[ "$status" -ne 0 ]]
  run cron_validate_schedule $'0 0 * * *\r'
  [[ "$status" -ne 0 ]]
  run cron_validate_schedule '0 0 * * %'
  [[ "$status" -ne 0 ]]
  rm -f "$CRON_STATE"
  run cron_register "test-module" $'0 0 * * *\n* * * * * touch /tmp/pwned'
  [[ "$status" -ne 0 ]]
  [[ ! -s "$CRON_STATE" ]]
  run cron_validate_schedule '0 0 * * *'
  [[ "$status" -eq 0 ]]
}

@test "cron_register: 重新启用主条目不删除变体条目（ops-report 年报）" {
  cron_register "ops-report" "0 1 * * 1"
  cron_register_variant "ops-report" "0 2 1 1 *" "--period 1y --email"
  run cron_register "ops-report" "0 3 * * 1"
  [[ "$status" -eq 0 ]]
  [[ "$(grep -c 'DEBNAS-CRON: ops-report' "$CRON_STATE")" -eq 2 ]]
  grep -q -- '--period 1y --email # DEBNAS-CRON: ops-report' "$CRON_STATE"
  grep -q '^0 3 \* \* 1 .* run ops-report # DEBNAS-CRON: ops-report$' "$CRON_STATE"
  [[ "$(grep -c '^0 1 \* \* 1' "$CRON_STATE")" -eq 0 ]]
}

@test "cron_register: 并发注册持锁，不丢条目" {
  # 使用每个测试独立的临时目录，避免上次运行（尤其 root）留下的目录导致 rm 失败
  export DEBNAS_TMP_BASE="$BATS_TEST_TMPDIR/cron-lock-base"
  rm -rf "$DEBNAS_TMP_BASE"
  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  # 读写之间留出时间窗，不加锁时并发注册必然互相覆盖
  cat > "$MOCK_BIN/crontab" << 'INNEREOF'
#!/usr/bin/env bash
state_file="${CRON_STATE:-/tmp/mock-crontab}"
case "$1" in
  -l) [[ -f "$state_file" ]] && cat "$state_file"; sleep 0.2; exit 0 ;;
  -r) rm -f "$state_file"; exit 0 ;;
  -)  cat > "$state_file.tmp.$$"; mv -f "$state_file.tmp.$$" "$state_file"; exit 0 ;;
esac
exit 1
INNEREOF
  chmod +x "$MOCK_BIN/crontab"
  rm -f "$CRON_STATE"
  local i
  for i in 1 2 3 4 5 6; do
    cron_register "mod$i" "0 1 * * 1" &
  done
  wait
  [[ "$(grep -c 'DEBNAS-CRON: mod' "$CRON_STATE")" -eq 6 ]]
}

# ==================== 跟进修复回归（2026-11-10）：没有 cron 的系统 ====================

# 在子进程里加载库并模拟"无 crontab 命令"的系统：PATH 只留一个空目录 + 必要工具的软链接
# 参数：$1 - 在加载库之后执行的片段
_cron_nocron_run() {
  local snippet="$1" bin="$BATS_TMPDIR/nocron-bin-$$"
  rm -rf "$bin"; mkdir -p "$bin"
  local t
  for t in bash awk sed grep cat id flock mkdir rm date sort head tr dirname basename mktemp chmod mv printf; do
    [[ -x "/usr/bin/$t" ]] && ln -sf "/usr/bin/$t" "$bin/$t"
  done
  env PATH="$bin" NOCRON_BIN="$bin" DEBNAS_ROOT="$DEBNAS_ROOT" SNIPPET="$snippet" CRON_STATE="$BATS_TMPDIR/nocron-state-$$" \
    /bin/bash -c '
    set -euo pipefail
    source "$DEBNAS_ROOT/lib/bootstrap.sh" >/dev/null 2>&1
    PATH="$NOCRON_BIN"
    # 桩：安装 cron = 往 PATH 里放一个 crontab；systemctl 状态由变量控制
    apt_install_packages() { echo "APT $*"; [[ "${APT_FAIL:-0}" == "1" ]] && return 1; printf "#!/bin/bash\ncase \"\$1\" in -l) cat \"\$CRON_STATE\" 2>/dev/null;; -) cat > \"\$CRON_STATE\";; esac\n" > "$NOCRON_BIN/crontab"; chmod +x "$NOCRON_BIN/crontab"; }
    systemctl() { local IFS=" "; case "$*" in *is-active*) [[ -e "$CRON_STATE.active" ]] ;; *is-enabled*) [[ -e "$CRON_STATE.enabled" ]] ;; *) return 0 ;; esac; }
    service_ensure() { echo "ENSURE $1 $2"; [[ "${START_FAIL:-0}" == "1" && "$2" == "started" ]] && return 1; [[ "$2" == "started" ]] && : > "$CRON_STATE.active"; [[ "$2" == "enabled" ]] && : > "$CRON_STATE.enabled"; return 0; }
    source /dev/stdin <<< "$SNIPPET"
  ' 2>&1
  local rc=$?
  rm -rf "$bin" "$BATS_TMPDIR/nocron-state-$$"*
  return $rc
}

@test "cron_register: 未安装 cron 时先安装并启动、设为自启，再写入条目" {
  [[ $EUID -eq 0 ]] || skip "需要 root（非 root 分支见下一条）"
  run _cron_nocron_run 'cron_register test-module "0 3 * * *"; echo "RC=$?"; crontab -l'
  [[ "$output" == *"APT cron"* ]]
  [[ "$output" == *"ENSURE cron started"* ]]
  [[ "$output" == *"ENSURE cron enabled"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"0 3 * * * DEBNAS_CRON_MODE=1 "*" run test-module # DEBNAS-CRON: test-module"* ]]
}

@test "cron_register: cron 安装失败时明确报错并返回非 0，不写条目" {
  [[ $EUID -eq 0 ]] || skip "需要 root"
  run _cron_nocron_run 'APT_FAIL=1; rc=0; cron_register test-module "0 3 * * *" || rc=$?; echo "RC=$rc"'
  [[ "$output" == *"cron 安装失败"* ]]
  [[ "$output" == *"RC=1"* ]]
}

@test "cron_register: cron 服务启动失败时明确报错并返回非 0，不写条目" {
  [[ $EUID -eq 0 ]] || skip "需要 root"
  run _cron_nocron_run 'START_FAIL=1; rc=0; cron_register test-module "0 3 * * *" || rc=$?; echo "RC=$rc"; crontab -l | grep -c test-module || true'
  [[ "$output" == *"cron 服务未运行且启动失败"* ]]
  [[ "$output" == *"RC=1"* ]]
  [[ "${lines[-1]}" == "0" ]]
}

@test "cron_register_variant: 同样先确保 cron 可用" {
  [[ $EUID -eq 0 ]] || skip "需要 root"
  run _cron_nocron_run 'cron_register_variant test-module "0 4 1 1 *" "--yearly"; echo "RC=$?"; crontab -l'
  [[ "$output" == *"APT cron"* ]]
  [[ "$output" == *"RC=0"* ]]
  [[ "$output" == *"run test-module --yearly # DEBNAS-CRON: test-module"* ]]
}

@test "cron_register: cron 已安装且在运行、已自启时不安装、不动服务、无额外输出" {
  run bash -c '
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    apt_install_packages() { echo APT; }
    service_ensure() { echo ENSURE; }
    systemctl() { return 0; }
    crontab() { return 0; }
    _cron_ensure_ready; echo "RC=$?"
  ' _ "$DEBNAS_ROOT"
  [[ "$output" == "RC=0" ]]
}

@test "cron: 交互菜单位于 UI 层，system 层不再依赖 ui_*" {
  grep -q '^cron_settings_menu()' "${DEBNAS_ROOT}/lib/ui/cron-menu.sh"
  grep -q '^cron_enable_interactive()' "${DEBNAS_ROOT}/lib/ui/cron-menu.sh"
  run grep -q '^cron_settings_menu()' "${DEBNAS_ROOT}/lib/system/cron.sh"
  [[ "$status" -ne 0 ]]
  run grep -qE '(^|[^_a-z])ui_(input|menu)([^_a-z]|$)' "${DEBNAS_ROOT}/lib/system/cron.sh"
  [[ "$status" -ne 0 ]]
  grep -q 'lib/ui/cron-menu.sh' "${DEBNAS_ROOT}/lib/bootstrap.sh"
}

@test "cron_register: 非 root 且无 crontab 命令时报错提示安装，返回非 0" {
  [[ $EUID -ne 0 ]] || skip "仅非 root 下验证"
  run _cron_nocron_run 'rc=0; cron_register test-module "0 3 * * *" || rc=$?; echo "RC=$rc"'
  [[ "$output" == *"未安装 cron"* ]]
  [[ "$output" == *"RC=1"* ]]
}
