#!/usr/bin/env bats
# 测试: modules/service-query.sh — 查询服务状态模块 (F-76, TC-P1-MOD-006)
# Mock 策略：PATH Injection Mock systemctl/docker/dpkg + 结构验证

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/service-query.sh"
export NO_COLOR=1

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "service-query: @module 为 service-query" {
  result=$(parse_meta "module")
  [[ "$result" == "service-query" ]]
}

@test "service-query: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "service-query: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "service-query: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "service-query: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "service-query: @depend_modules 为 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == "cockpit" ]]
}

# ==================== 语法验证 ====================

@test "service-query: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "service-query: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "service-query: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "service-query: 加载 lib/system/state.sh" {
  grep -q 'source.*lib/system/state.sh' "$MODULE_FILE"
}

@test "service-query: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "service-query: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 函数完整性验证 ====================

@test "service-query: 定义 is_service_active 函数" {
  grep -q '^is_service_active()' "$MODULE_FILE"
}

@test "service-query: is_service_active 使用 systemctl is-active" {
  sed -n '/^is_service_active()/,/^}/p' "$MODULE_FILE" | grep -q 'systemctl is-active'
}

@test "service-query: 定义 print_service_status 函数" {
  grep -q '^print_service_status()' "$MODULE_FILE"
}

@test "service-query: print_service_status 输出服务已运行和访问 URL" {
  sed -n '/^print_service_status()/,/^}/p' "$MODULE_FILE" | grep -q '已运行'
  sed -n '/^print_service_status()/,/^}/p' "$MODULE_FILE" | grep -q '请通过浏览器访问'
}

@test "service-query: 定义 check_system_services 函数" {
  grep -q '^check_system_services()' "$MODULE_FILE"
}

@test "service-query: check_system_services 只查询不启动 cockpit" {
  ! sed -n '/^check_system_services()/,/^}/p' "$MODULE_FILE" | grep -q 'service_ensure' || false
  sed -n '/^check_system_services()/,/^}/p' "$MODULE_FILE" | grep -q 'cockpit.socket'
}

@test "service-query: check_system_services 输出 cockpit 访问地址" {
  sed -n '/^check_system_services()/,/^}/p' "$MODULE_FILE" | grep -q 'cockpit'
  sed -n '/^check_system_services()/,/^}/p' "$MODULE_FILE" | grep -q '9090'
}

@test "service-query: 定义 check_docker_containers 函数" {
  grep -q '^check_docker_containers()' "$MODULE_FILE"
}

@test "service-query: check_docker_containers 扫描 compose 目录" {
  sed -n '/^check_docker_containers()/,/^}/p' "$MODULE_FILE" | grep -q 'compose'
}

@test "service-query: check_docker_containers 读取 @web_port 元数据" {
  grep -q '@web_port' "$MODULE_FILE"
}

@test "service-query: 包检测使用公共 pkg_is_installed（不再自写 dpkg -s）" {
  grep -q 'pkg_is_installed firewalld' "$MODULE_FILE"
  ! grep -qE '^is_package_installed\(\)|dpkg -s|dpkg-query' "$MODULE_FILE" || false
}

@test "service-query: Web 容器按 compose 的 container_name 查询运行状态" {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/compose"
  printf '# @web_port: 9443\nservices:\n  p:\n    container_name: "my-portainer"\n' > "$d/compose/portainer.yaml"
  printf '# @web_port: 8080\nservices:\n  w:\n    image: x\n' > "$d/compose/web.yml"
  printf 'services:\n  n:\n    image: x\n' > "$d/compose/noweb.yaml"
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    SCRIPT_DIR="$3"; log_success() { echo "OK:$*"; }; log_info() { echo "I:$*"; }
    LOG="$3/inspect.log"; docker() { echo "INSPECT:${*: -1}" >> "$LOG"; [[ "${*: -1}" == my-portainer || "${*: -1}" == web ]] && echo true; }
    check_docker_containers 1.2.3.4' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$d"
  local inspected
  inspected=$(< "$d/inspect.log")
  rm -rf -- "$d"
  [[ "$inspected" == *"INSPECT:my-portainer"* && "$inspected" == *"INSPECT:web"* ]]
  [[ "$inspected" != *"INSPECT:noweb"* ]]
  [[ "$output" == *"I:请通过浏览器访问：https://1.2.3.4:9443"* ]]
  [[ "$output" == *"I:请通过浏览器访问：https://1.2.3.4:8080"* ]]
}

@test "service-query: 定义 display_firewalld_fail2ban_info 函数" {
  grep -q '^display_firewalld_fail2ban_info()' "$MODULE_FILE"
}

@test "service-query: display_firewalld_fail2ban_info 检查 firewalld 和 fail2ban" {
  sed -n '/^display_firewalld_fail2ban_info()/,/^}/p' "$MODULE_FILE" | grep -q 'firewalld'
  sed -n '/^display_firewalld_fail2ban_info()/,/^}/p' "$MODULE_FILE" | grep -q 'fail2ban'
}

@test "service-query: main 获取主机 IP（hostname -I）" {
  sed -n '/^main()/,/^}/p' "$MODULE_FILE" | grep -q 'hostname -I'
}

@test "service-query: main 检查 docker 服务状态再扫描容器" {
  sed -n '/^main()/,/^}/p' "$MODULE_FILE" | grep -q 'is_service_active docker'
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

@test "service-query: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "service-query: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "service-query: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "service-query: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "service-query: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status service-query
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan service-query
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- service-query 专项 ----------

@test "service-query: 只读工具，plan 为 info|-|只读查询，不修改系统" {
  run _contract_probe plan
  [[ "$output" == "info|-|只读查询，不修改系统"* ]]
  [[ "$output" != *$'\n'* ]]
}

@test "service-query: status 不计入完成度（unknown/warn）并注明只读工具" {
  run _contract_probe status
  [[ "$output" =~ ^(unknown|warn)\|只读工具 ]]
}
