#!/usr/bin/env bats
# 测试: modules/cockpit-ext/ — Cockpit 外网访问目录模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/cockpit-ext"
MODULE_FILE="${MODULE_DIR}/module.sh"
ACTIONS_FILE="${MODULE_DIR}/actions.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "cockpit-ext: @module 为 cockpit-ext" {
  result=$(parse_meta "module")
  [[ "$result" == "cockpit-ext" ]]
}

@test "cockpit-ext: @name 为 Cockpit 外网访问" {
  result=$(parse_meta "name")
  [[ "$result" == "Cockpit 外网访问" ]]
}

@test "cockpit-ext: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "cockpit-ext: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "cockpit-ext: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "cockpit-ext: @depend_modules 声明依赖 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"cockpit"* ]]
}

@test "cockpit-ext: @interactive 为 true" {
  result=$(parse_meta "interactive")
  [[ "$result" == "true" ]]
}

# ==================== 语法验证 ====================

@test "cockpit-ext: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "cockpit-ext: actions.sh bash -n 语法通过" {
  run bash -n "$ACTIONS_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "cockpit-ext: module.sh 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "cockpit-ext: module.sh 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "cockpit-ext: module.sh main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "cockpit-ext: module.sh 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "cockpit-ext: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$ACTIONS_FILE" | grep -q '\<eval\>'
}

@test "cockpit-ext: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$ACTIONS_FILE"
}

# ==================== 函数定义验证 ====================

@test "cockpit-ext: enable_cockpit_ext 函数已定义" {
  grep -q '^enable_cockpit_ext()' "$ACTIONS_FILE"
}

@test "cockpit-ext: disable_cockpit_ext 函数已定义" {
  grep -q '^disable_cockpit_ext()' "$ACTIONS_FILE"
}

# ==================== 逻辑验证 ====================

@test "cockpit-ext: module.sh 通过 ui_menu 路由到 enable/disable" {
  grep -q 'enable_cockpit_ext' "$MODULE_FILE"
  grep -q 'disable_cockpit_ext' "$MODULE_FILE"
}

@test "cockpit-ext: enable_cockpit_ext 操作 /etc/cockpit/cockpit.conf" {
  grep -q '/etc/cockpit/cockpit.conf' "$ACTIONS_FILE"
}

@test "cockpit-ext: enable_cockpit_ext 使用 write_file_if_changed 安全写入" {
  grep -q 'write_file_if_changed' "$ACTIONS_FILE"
}

@test "cockpit-ext: enable_cockpit_ext 使用 service_ensure 重启 cockpit" {
  grep -q 'service_ensure.*cockpit.*restarted' "$ACTIONS_FILE"
}

@test "cockpit-ext: disable_cockpit_ext 使用 sed 移除 Origins 行" {
  grep -q 'sed.*Origins' "$ACTIONS_FILE"
}

# ==================== 回归：注释行 / IPv6 / 菜单不退出 ====================

@test "cockpit-ext: 只匹配未注释的 Origins 行" {
  grep -q "\^\[\[:space:\]\]\*Origins\[\[:space:\]\]\*=" "$ACTIONS_FILE"
  ! grep -q "sed '/Origins/d'" "$ACTIONS_FILE"
}

@test "cockpit-ext: IPv6 地址加方括号" {
  grep -q 'domain="\[${domain}\]"' "$ACTIONS_FILE"
  grep -q 'internal_ip="\[${internal_ip}\]"' "$ACTIONS_FILE"
}

@test "cockpit-ext: 菜单中启用/禁用失败不退出工具" {
  grep -q 'enable_cockpit_ext || true' "$MODULE_FILE"
  grep -q 'disable_cockpit_ext || true' "$MODULE_FILE"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 探测方式与 lib/system/module-probe.sh 一致：预加载库 + _DEBNAS_BOOTSTRAPPED=1 + DEBNAS_MODULE_ACTION=status|plan 后 source。
# source 期间把常见"执行动作"类函数替换为写标记文件，用于断言探测时 main 未执行。

# 参数：$1 — status|plan|eval，$2 — 标记文件，$3 — eval 时在 source 后执行的脚本片段
_contract_probe() {
  local action="$1" marker="$2" snippet="${3:-}"
  local probe_action="$action"
  [[ "$action" == "eval" ]] && probe_action="status"
  DEBNAS_MODULE_ACTION="$probe_action" _CT_MARKER="$marker" _CT_SNIPPET="$snippet" \
    bash -c '
      set -euo pipefail
      source "$1/lib/bootstrap.sh" >/dev/null 2>&1 || exit 90
      _DEBNAS_BOOTSTRAPPED=1
      _CT_SOURCING=1
      _ct_mark() { [[ -n "${_CT_SOURCING:-}" ]] && echo "$1" >> "$_CT_MARKER"; return 0; }
      log_info() { _ct_mark log_info; }
      log_success() { _ct_mark log_success; }
      log_warning() { _ct_mark log_warning; }
      log_error() { _ct_mark log_error; }
      ui_progress_step() { _ct_mark ui_progress_step; }
      ui_menu() { _ct_mark ui_menu; return 255; }
      register_temp_cleanup() { _ct_mark register_temp_cleanup; }
      create_temp_file() { _ct_mark create_temp_file; echo /dev/null; }
      check_dependencies() { _ct_mark check_dependencies; return 0; }
      apt_install_packages() { _ct_mark apt_install_packages; return 0; }
      service_ensure() { _ct_mark service_ensure; return 0; }
      write_file_if_changed() { _ct_mark write_file_if_changed; return 1; }
      source "$2" </dev/null >/dev/null 2>&1 || exit 91
      unset _CT_SOURCING
      case "$DEBNAS_MODULE_ACTION" in
        status) if [[ -n "$_CT_SNIPPET" ]]; then source /dev/stdin <<< "$_CT_SNIPPET"; else module_status; fi ;;
        plan) module_plan ;;
      esac
    ' _ "$DEBNAS_ROOT" "$MODULE_FILE" </dev/null 2>/dev/null
}

_contract_status_ok() {
  [[ "$(printf '%s\n' "$1" | grep -c .)" -eq 1 ]] || return 1
  [[ "$1" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+$ ]]
}

_contract_plan_ok() {
  local line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.*$ ]] || return 1
    n=$((n + 1))
  done <<< "$1"
  [[ $n -gt 0 ]]
}

@test "cockpit-ext: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "cockpit-ext: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "cockpit-ext: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-cockpit-ext-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "cockpit-ext: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-cockpit-ext-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "cockpit-ext: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-cockpit-ext-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "cockpit-ext: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status cockpit-ext
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan cockpit-ext
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "cockpit-ext: Origins 已配置时 status=applied 并显示域名" {
  local conf="$BATS_TMPDIR/ct-cockpit.conf"
  printf '[WebService]\nOrigins = https://nas.example.com:9443 wss://nas.example.com:9443 https://192.168.1.2:9090\n' > "$conf"
  run _contract_probe eval /dev/null "
    _COCKPIT_EXT_CONF='$conf'
    _cockpit_ext_installed() { return 0; }
    systemctl() { return 0; }
    module_status"
  [[ "$output" == "applied|外网访问已配置：nas.example.com:9443, 192.168.1.2:9090" ]]
  rm -f "$conf"
}

@test "cockpit-ext: 只有注释的 Origins 视为未配置" {
  local conf="$BATS_TMPDIR/ct-cockpit.conf"
  printf '[WebService]\n# Origins = https://x\n' > "$conf"
  run _contract_probe eval /dev/null "
    _COCKPIT_EXT_CONF='$conf'
    _cockpit_ext_installed() { return 0; }
    module_status"
  [[ "$output" == absent\|* ]]
  rm -f "$conf"
}

@test "cockpit-ext: plan 列出交互动作与外网暴露风险" {
  run _contract_probe plan /dev/null
  [[ "$output" == *"info|cockpit-ext|交互式菜单"* ]]
  [[ "$output" == *"risk|外网暴露|"* ]]
}
