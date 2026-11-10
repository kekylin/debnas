#!/usr/bin/env bats
# 测试: modules/timer-manager.sh — 定时任务概览（只读探测契约）
# Mock 策略：结构验证 + 以 DEBNAS_MODULE_ACTION 加载模块调用契约函数

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/timer-manager.sh"

@test "timer-manager: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "timer-manager: 非 root 时 module_status 降级为 unknown" {
  [[ "$EUID" -ne 0 ]] || skip "需以普通用户运行"
  run env DEBNAS_MODULE_ACTION=status bash -c 'source "$1" </dev/null >/dev/null 2>&1; module_status' _ "$MODULE_FILE"
  [[ "$output" == unknown\|* ]]
}

@test "timer-manager: module_plan 只有 info 行（不修改 crontab）" {
  run env DEBNAS_MODULE_ACTION=plan bash -c 'source "$1" </dev/null >/dev/null 2>&1; module_plan' _ "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
  ! grep -qv '^info|' <<<"$output"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/timer-manager.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/timer-manager-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/timer-manager-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "timer-manager-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "timer-manager-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "timer-manager-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "timer-manager-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/timer-manager-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "timer-manager-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "timer-manager-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "timer-manager-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/timer-manager-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status timer-manager
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

@test "timer-manager: [D7] crontab 只剩变体条目（ops-report 年报）时概览不中止" {
  local mock="${BATS_TEST_TMPDIR}/bin-d7"
  mkdir -p "$mock"
  cat > "$mock/crontab" <<'M'
#!/bin/bash
[[ "${1:-}" == "-l" ]] || exit 1
echo '0 3 1 1 * DEBNAS_CRON_MODE=1 /usr/local/bin/debnas run ops-report 365 # DEBNAS-CRON: ops-report'
M
  chmod +x "$mock/crontab"
  run env PATH="$mock:$PATH" DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TEST_TMPDIR}/st" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; set -euo pipefail; _timer_list_all; echo "DONE"' _ "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"DONE"* ]]
  [[ "$output" == *"仅有附加周期条目"* ]]
}
