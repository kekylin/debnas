#!/usr/bin/env bats
# 测试: modules/vm-components.sh — 安装虚拟机组件模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/vm-components.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "vm-components: @module 为 vm-components" {
  result=$(parse_meta "module")
  [[ "$result" == "vm-components" ]]
}

@test "vm-components: @name 为 安装虚拟机组件" {
  result=$(parse_meta "name")
  [[ "$result" == "安装虚拟机组件" ]]
}

@test "vm-components: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "vm-components: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "vm-components: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "vm-components: @depend_modules 声明依赖 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"cockpit"* ]]
}

# ==================== 语法验证 ====================

@test "vm-components: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "vm-components: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "vm-components: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "vm-components: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "vm-components: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "vm-components: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "vm-components: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "vm-components: 使用 get_system_codename 获取系统代号" {
  grep -q 'get_system_codename' "$MODULE_FILE"
}

@test "vm-components: 使用 pinning_file_exists 只读判断 Pinning 文件（不再调带日志的 check_pinning_status）" {
  sed -n '/^main()/,/^}/p' "$MODULE_FILE" | grep -q 'pinning_file_exists "$VM_PINNING_FILE"'
  sed -n '/^module_plan()/,/^}/p' "$MODULE_FILE" | grep -q 'pinning_file_exists "$VM_PINNING_FILE"'
  ! grep -q 'check_pinning_status' "$MODULE_FILE" || false
}

@test "vm-components: plan 与 main 共用 _vm_ip_forward_overrides 检出覆盖 ip_forward 的片段" {
  [[ "$(grep -c '_vm_ip_forward_overrides)' "$MODULE_FILE")" -eq 2 ]]
}

@test "vm-components: 使用 configure_cockpit_pinning 配置 Pinning" {
  grep -q 'configure_cockpit_pinning' "$MODULE_FILE"
}

@test "vm-components: 使用 apply_pinning_config 应用 Pinning 配置" {
  grep -q 'apply_pinning_config' "$MODULE_FILE"
}

@test "vm-components: 使用 apt_install_packages 安装 cockpit-machines" {
  grep -q 'apt_install_packages cockpit-machines' "$MODULE_FILE"
}

@test "vm-components: 使用 sysctl_persist 配置 net.ipv4.ip_forward" {
  grep -q 'sysctl_persist' "$MODULE_FILE"
  grep -q 'net.ipv4.ip_forward' "$MODULE_FILE"
}

@test "vm-components: 写入 10-debnas-network.conf sysctl 配置文件" {
  grep -q '10-debnas-network.conf' "$MODULE_FILE"
}

@test "vm-components: 使用 service_ensure cockpit restarted 重启服务" {
  grep -q 'service_ensure.*cockpit.*restarted' "$MODULE_FILE"
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

@test "vm-components: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "vm-components: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "vm-components: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "vm-components: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "vm-components: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status vm-components
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan vm-components
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- vm-components 专项 ----------

@test "vm-components: status 反映 cockpit-machines/libvirtd/ip_forward" {
  run _contract_probe status
  [[ "$output" == *"ip_forward"* ]]
}

@test "vm-components: plan 如实说明 sysctl 经 sysctl_persist 写入（有备份）并重启 cockpit" {
  run _contract_probe plan "VM_SYSCTL_CONF='$BATS_TMPDIR/nosuch-debnas.conf'"
  [[ "$output" == *"write|$BATS_TMPDIR/nosuch-debnas.conf|"*"sysctl_persist"*"/var/backups/debnas/"* ]]
  [[ "$output" != *"不另做备份"* ]]
  [[ "$output" == *"service|cockpit|"* ]]
}

# ==================== 跟进修复回归（2026-11-10）：不再 sed -i 直改 /etc/sysctl.conf ====================

@test "vm-components: 模块内无 sed -i 原地修改系统文件" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qE 'sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i' || false
}

@test "vm-components: main 注释 sysctl.conf 的 ip_forward 经 write_file_if_changed（原件进备份、路径进文件清单）" {
  local tmp
  tmp=$(mktemp -d)
  printf '# c\nnet.ipv4.ip_forward=0\n  net.ipv4.ip_forward = 0\nvm.swappiness = 10\n' > "$tmp/sysctl.conf"
  run env DEBNAS_BACKUP_ROOT="$tmp/backups" DEBNAS_MANIFEST_FILE="$tmp/manifest" DEBNAS_GLOBAL_CONF="$tmp/none" \
    DEBNAS_BACKUP_ENABLED=1 DEBNAS_MODULE_ACTION=status bash -c '
    set -euo pipefail
    source "$1/lib/bootstrap.sh" >/dev/null 2>&1
    source "$2" </dev/null
    get_system_codename() { echo trixie; }
    pinning_file_exists() { return 0; }
    apt_install_packages() { return 0; }
    sysctl_persist() { return 0; }
    service_ensure() { return 0; }
    _vm_ip_forward_overrides() { return 0; }
    eval "$(declare -f main | sed "s#/etc/sysctl.conf#$3/sysctl.conf#")"
    main >/dev/null 2>&1
    cat "$3/sysctl.conf"
  ' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$tmp"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *$'\n'"# net.ipv4.ip_forward = 0"* ]]
  [[ "$output" == *"  # net.ipv4.ip_forward = 0"* ]]
  [[ "$output" == *"vm.swappiness = 10"* ]]
  ! grep -qE '^[[:space:]]*net\.ipv4\.ip_forward' "$tmp/sysctl.conf" || false
  grep -qx 'net.ipv4.ip_forward=0' "$tmp/backups/original$tmp/sysctl.conf"
  grep -qF "$tmp/sysctl.conf" "$tmp/manifest"
  rm -rf "$tmp"
}

# ==================== 状态判定（行为） ====================

@test "vm-components: _vm_libvirtd_active 兼容 service 与 socket" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/vm-components.sh" >/dev/null 2>&1
    systemctl() { [[ "$1 $2 $3" == "is-active --quiet libvirtd.socket" ]]; }
    _vm_libvirtd_active && echo SOCKET
    systemctl() { return 1; }
    _vm_libvirtd_active || echo NONE
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"SOCKET"* ]]
  [[ "$output" == *"NONE"* ]]
}

@test "vm-components: module_status 区分未安装/未运行/未转发/运行中" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/vm-components.sh" >/dev/null 2>&1
    pkg_is_installed() { return 1; }
    _vm_ip_forward() { echo 0; }
    module_status

    pkg_is_installed() { return 0; }
    _vm_libvirtd_active() { return 1; }
    module_status

    _vm_libvirtd_active() { return 0; }
    _vm_ip_forward() { echo 0; }
    module_status

    _vm_ip_forward() { echo 1; }
    module_status
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"absent|未安装 cockpit-machines"* ]]
  [[ "$output" == *"warn|cockpit-machines 已安装，libvirtd 未运行"* ]]
  [[ "$output" == *"partial|libvirtd 运行中，IP 转发未开启"* ]]
  [[ "$output" == *"running|libvirtd 运行中 · ip_forward=1"* ]]
}
