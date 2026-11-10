#!/usr/bin/env bats
# 测试: modules/sys-check.sh — 检查兼容性模块 (F-70~F-72, TC-P1-MOD-005)
# Mock 策略：结构验证 + PATH Injection Mock (df/free/uname/curl) 功能测试

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/sys-check.sh"
export NO_COLOR=1

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "sys-check: @module 为 sys-check" {
  result=$(parse_meta "module")
  [[ "$result" == "sys-check" ]]
}

@test "sys-check: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "sys-check: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "sys-check: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "sys-check: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "sys-check: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "sys-check: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "sys-check: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "sys-check: 加载 lib/system/state.sh" {
  grep -q 'source.*lib/system/state.sh' "$MODULE_FILE"
}

@test "sys-check: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "sys-check: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 检查项结构验证 ====================

@test "sys-check: 定义 check_system_compatibility 函数" {
  grep -q '^check_system_compatibility()' "$MODULE_FILE"
}

@test "sys-check: 包含系统版本检查（verify_system_support）" {
  grep -q 'verify_system_support' "$MODULE_FILE"
}

@test "sys-check: 包含系统架构检查（verify_architecture_support）" {
  grep -q 'verify_architecture_support' "$MODULE_FILE"
}

@test "sys-check: 包含内存检查（/proc/meminfo）" {
  grep -q '/proc/meminfo' "$MODULE_FILE"
}

@test "sys-check: 内存低于 1GB 时输出警告（mem_mb < 1024 判断）" {
  grep -q 'mem_mb.*1024' "$MODULE_FILE"
}

@test "sys-check: 包含磁盘空间检查（df /）" {
  grep -q 'df /' "$MODULE_FILE"
}

@test "sys-check: 磁盘低于 10GB 时输出警告（disk_gb < 10 判断）" {
  grep -q 'disk_gb.*10' "$MODULE_FILE"
}

@test "sys-check: 包含网络连通性检查（镜像站探测）" {
  grep -q 'APT_MIRRORS' "$MODULE_FILE"
}

@test "sys-check: 网络检查全部不可用时输出错误" {
  grep -q '所有镜像站均不可用' "$MODULE_FILE"
}

@test "sys-check: 包含 SSH 服务状态检查" {
  grep -q 'ssh' "$MODULE_FILE"
}

@test "sys-check: 包含 Cron 服务状态检查" {
  grep -q 'cron' "$MODULE_FILE"
}

@test "sys-check: 全部通过时输出 '适合运行项目脚本'" {
  grep -q '适合运行项目脚本' "$MODULE_FILE"
}

@test "sys-check: 存在问题风险时输出 '存在风险'" {
  grep -q '存在风险' "$MODULE_FILE"
}

@test "sys-check: 使用 curl --max-time 5 超时保护" {
  grep -q 'curl.*--max-time 5' "$MODULE_FILE"
}

@test "sys-check: 存在 REQUIRED_CMDS 依赖检查" {
  grep -q 'REQUIRED_CMDS=' "$MODULE_FILE"
}

@test "sys-check: REQUIRED_CMDS 包含 awk/grep/df/uname/curl" {
  grep -q 'REQUIRED_CMDS=' "$MODULE_FILE"
  local line
  line=$(grep 'REQUIRED_CMDS=' "$MODULE_FILE")
  [[ "$line" == *"awk"* ]]
  [[ "$line" == *"grep"* ]]
  [[ "$line" == *"df"* ]]
  [[ "$line" == *"uname"* ]]
  [[ "$line" == *"curl"* ]]
}

# ==================== 函数完整性验证 ====================

@test "sys-check: issues 数组分系统/资源/网络三类（服务检查只提示不计入问题）" {
  grep -q 'issues_system=()' "$MODULE_FILE"
  grep -q 'issues_resource=()' "$MODULE_FILE"
  grep -q 'issues_network=()' "$MODULE_FILE"
  ! grep -q 'issues_service' "$MODULE_FILE" || false
}

@test "sys-check: module_status 用公共函数读系统 ID/代号（不再自行 source os-release）" {
  sed -n '/^module_status()/,/^}/p' "$MODULE_FILE" | grep -q '_get_os_id'
  sed -n '/^module_status()/,/^}/p' "$MODULE_FILE" | grep -q 'get_system_codename'
  ! grep -q '\. /etc/os-release' "$MODULE_FILE" || false
}

@test "sys-check: _sys_check_mem_kb 读出 MemTotal" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"; _sys_check_mem_kb' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$output" =~ ^[0-9]+$ ]]
  [[ "$output" == "$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)" ]]
}

@test "sys-check: 检查结论输出包含格式标记" {
  grep -q '检查结论' "$MODULE_FILE"
  grep -q '兼容性结论' "$MODULE_FILE"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 以 DEBNAS_MODULE_ACTION=<动作> 加载模块并调用契约函数
# 参数：$1 status|plan；$2 加载模块后、调用契约函数前执行的额外 bash 代码（可选，如覆盖路径变量）
# 说明：log_* / check_dependencies / verify_debian_12_13_support / apt_install_packages /
#       write_file_if_changed / service_ensure 被替换为输出 MAIN-RAN 的桩——
#       模块顶层或 main 若被执行，输出中会出现 MAIN-RAN
_contract_probe() {
  local action="$1" extra="${2:-}"
  DEBNAS_ROOT="$DEBNAS_ROOT" MODULE_FILE="$MODULE_FILE" ACTION="$action" EXTRA="$extra" bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    source "${DEBNAS_ROOT}/lib/bootstrap.sh" >/dev/null 2>&1
    log_info() { echo MAIN-RAN; }
    log_warning() { echo MAIN-RAN; }
    log_error() { echo MAIN-RAN; }
    log_success() { echo MAIN-RAN; }
    check_dependencies() { echo MAIN-RAN; return 1; }
    verify_debian_12_13_support() { echo MAIN-RAN; return 1; }
    apt_install_packages() { echo MAIN-RAN; return 1; }
    write_file_if_changed() { echo MAIN-RAN; return 2; }
    service_ensure() { echo MAIN-RAN; return 1; }
    export DEBNAS_MODULE_ACTION="$ACTION"
    source "$MODULE_FILE" </dev/null
    if [[ -n "$EXTRA" ]]; then source /dev/stdin <<< "$EXTRA"; fi
    "module_${ACTION}" </dev/null
  ' 2>/dev/null
}

# 断言：输出恰为一行合法状态
_assert_status_line() {
  [[ -n "$1" ]]
  [[ "$1" != *$'\n'* ]]
  [[ "$1" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

# 断言：每行为合法预演类型的三段式
_assert_plan_lines() {
  local line
  [[ -n "$1" ]]
  while IFS= read -r line; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法预演行：$line"; return 1; }
  done <<< "$1"
}

@test "sys-check: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "sys-check: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "sys-check: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "sys-check: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "sys-check: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status sys-check
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan sys-check
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- sys-check 专项 ----------

@test "sys-check: 只读工具，plan 为 info|-|只读查询，不修改系统" {
  run _contract_probe plan
  [[ "$output" == "info|-|只读查询，不修改系统"* ]]
  [[ "$output" != *$'\n'* ]]
}

@test "sys-check: status 不计入完成度（unknown/warn）并注明只读工具" {
  run _contract_probe status
  [[ "$output" =~ ^(unknown|warn)\|只读工具 ]]
}

@test "sys-check: 依赖检查已移入 main（顶层不 exit）" {
  ! grep -qE '^if ! check_dependencies' "$MODULE_FILE" || false
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'check_dependencies'
}
