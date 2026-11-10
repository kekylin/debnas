#!/usr/bin/env bats
# 测试: modules/basic-tools.sh — 安装基础工具模块 (F-05~F-06)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/basic-tools.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "basic-tools: @module 为 basic-tools" {
  result=$(parse_meta "module")
  [[ "$result" == "basic-tools" ]]
}

@test "basic-tools: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "basic-tools: @category 为 基础系统" {
  result=$(parse_meta "category")
  [[ "$result" == "基础系统" ]]
}

@test "basic-tools: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "basic-tools: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "basic-tools: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "basic-tools: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "basic-tools: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "basic-tools: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "basic-tools: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "basic-tools: 无 eval 动态命令执行" {
  # 排除注释行中的 eval 引用
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "basic-tools: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "basic-tools: main 检查 apt/awk 依赖" {
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'check_dependencies apt awk'
}

@test "basic-tools: 调用 check_dependencies 检查必备命令" {
  grep -q 'check_dependencies' "$MODULE_FILE"
}

@test "basic-tools: 调用 apt_install_packages 安装软件包" {
  grep -q 'apt_install_packages' "$MODULE_FILE"
}

@test "basic-tools: 调用 get_primary_user 获取普通用户" {
  grep -q 'get_primary_user' "$MODULE_FILE"
  ! grep -q 'get_first_regular_user' "$MODULE_FILE" || false
}

@test "basic-tools: usermod 添加用户到 sudo 组" {
  grep -q 'usermod.*sudo' "$MODULE_FILE"
}

@test "basic-tools: id 检查用户是否已在 sudo 组（不经 grep 管道）" {
  sed -n '/^_basic_tools_in_sudo() {/,/^}/p' "$MODULE_FILE" | grep -q 'id -nG'
  ! grep -q 'id -nG.*| *grep' "$MODULE_FILE" || false
}

@test "basic-tools: _basic_tools_in_sudo 按整词匹配 sudo 组" {
  run bash -c "source '${DEBNAS_ROOT}/lib/bootstrap.sh' >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source '$MODULE_FILE'
    id() { echo 'u adm sudoers'; }; _basic_tools_in_sudo u && echo IN || echo OUT
    id() { echo 'u sudo'; }; _basic_tools_in_sudo u && echo IN || echo OUT"
  [[ "$output" == $'OUT\nIN' ]]
}

@test "basic-tools: add_user_to_sudo=false 也视为关闭" {
  run _contract_probe plan "get_primary_user() { echo nosuchuser-debnas; }; config_read() { echo false; }"
  [[ "$output" == *"add_user_to_sudo=0"* ]]
  [[ "$output" != *"user|"* ]]
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

@test "basic-tools: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "basic-tools: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "basic-tools: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "basic-tools: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "basic-tools: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status basic-tools
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan basic-tools
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- basic-tools 专项 ----------

@test "basic-tools: 安装清单与探测共用 BASIC_TOOLS_PACKAGES" {
  grep -q '^BASIC_TOOLS_PACKAGES=(' "$MODULE_FILE"
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'apt_install_packages "${BASIC_TOOLS_PACKAGES\[@\]}"'
}

@test "basic-tools: status 报告已装数量" {
  run _contract_probe status
  [[ "$output" =~ ^(applied|partial|absent)\|.*[0-9]+/[0-9]+ ]]
}

@test "basic-tools: plan 只列未安装的包，sudo 组变更受 add_user_to_sudo 控制" {
  run _contract_probe plan "BASIC_TOOLS_PACKAGES=(bash nosuch-debnas-pkg); get_primary_user() { echo nosuchuser-debnas; }; config_read() { echo 1; }"
  [[ "$output" == *"pkg|nosuch-debnas-pkg|"* ]]
  [[ "$output" != *"pkg|bash"* ]]
  [[ "$output" == *"user|nosuchuser-debnas|加入 sudo 组"* ]]
  [[ "$output" == *"risk|sudo 组|"* ]]
  run _contract_probe plan "get_primary_user() { echo nosuchuser-debnas; }; config_read() { echo 0; }"
  [[ "$output" != *"user|"* ]]
  [[ "$output" == *"add_user_to_sudo=0"* ]]
}
