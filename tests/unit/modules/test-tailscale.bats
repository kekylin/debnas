#!/usr/bin/env bats
# 测试: modules/tailscale.sh — 安装 Tailscale 内网穿透模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/tailscale.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "tailscale: @module 为 tailscale" {
  result=$(parse_meta "module")
  [[ "$result" == "tailscale" ]]
}

@test "tailscale: @name 为 安装 Tailscale" {
  result=$(parse_meta "name")
  [[ "$result" == "安装 Tailscale" ]]
}

@test "tailscale: @category 为 系统工具" {
  result=$(parse_meta "category")
  [[ "$result" == "系统工具" ]]
}

@test "tailscale: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "tailscale: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "tailscale: @depends 声明依赖 curl" {
  result=$(parse_meta "depends")
  [[ "$result" == *"curl"* ]]
}

# ==================== 语法验证 ====================

@test "tailscale: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "tailscale: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "tailscale: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "tailscale: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "tailscale: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "tailscale: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "tailscale: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "tailscale: 使用 get_system_codename 获取系统代号" {
  grep -q 'get_system_codename' "$MODULE_FILE"
}

@test "tailscale: GPG 密钥文件路径 tailscale-archive-keyring.gpg" {
  grep -q 'tailscale-archive-keyring.gpg' "$MODULE_FILE"
}

@test "tailscale: APT 源以 DEB822 幂等写入 tailscale.sources（Signed-By 指向 keyring）" {
  grep -q 'write_file_if_changed "\${TAILSCALE_SOURCES_DIR}/tailscale.sources"' "$MODULE_FILE"
  grep -q '^Signed-By: \${TAILSCALE_KEYRING_FILE}' "$MODULE_FILE"
  grep -q 'TAILSCALE_SOURCES_DIR:-/etc/apt/sources.list.d' "$MODULE_FILE"
}

@test "tailscale: 旧 tailscale.list 备份停用避免重复源" {
  grep -q 'debnas_backup_file "${TAILSCALE_SOURCES_DIR}/tailscale.list"' "$MODULE_FILE"
}

@test "tailscale: 使用 apt_install_packages 安装 tailscale" {
  grep -q 'apt_install_packages tailscale' "$MODULE_FILE"
}

@test "tailscale: 提示用户运行 tailscale up 完成认证" {
  grep -q 'tailscale up' "$MODULE_FILE"
}

# ==================== 指纹校验 ====================

@test "tailscale: 固定 Tailscale 公钥主密钥指纹" {
  grep -q '^TAILSCALE_GPG_FINGERPRINT="2596A99EAAB33821893C0A79458CA832957F5868"' "$MODULE_FILE"
}

@test "tailscale: 公钥经 keyring_install_verified 下载校验（--dearmor），不再自写 curl/gpg" {
  grep -q 'keyring_install_verified "\$key_url" "\$TAILSCALE_GPG_FINGERPRINT" "\$TAILSCALE_KEYRING_FILE" --dearmor' "$MODULE_FILE"
  ! grep -qE 'gpg .*--show-keys|^[[:space:]]*curl |verify_tailscale_gpg_fingerprint|read_tailscale_url' "$MODULE_FILE" || false
  grep -q 'config_get_url repo_tailscale_url' "$MODULE_FILE"
}

@test "tailscale: 公钥安装失败时 main 以 ERROR_DEPENDENCY 退出，且不写源" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    check_dependencies() { return 0; }; get_system_codename() { echo trixie; }; config_read() { echo "${3:-}"; }
    log_info() { :; }; log_error() { :; }
    keyring_install_verified() { local IFS=" "; echo "KIV:$*"; return 1; }
    write_file_if_changed() { echo WROTE; }
    main' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$status" -eq 2 ]]  # ERROR_DEPENDENCY
  [[ "$output" == *"KIV:https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg 2596A99EAAB33821893C0A79458CA832957F5868 /usr/share/keyrings/tailscale-archive-keyring.gpg --dearmor --label Tailscale"* ]]
  [[ "$output" != *WROTE* ]]
}

@test "tailscale: 仓库/公钥地址可通过 debnas.conf 配置，默认官方地址" {
  grep -q '^TAILSCALE_DEFAULT_REPO_URL="https://pkgs.tailscale.com/stable/debian"' "$MODULE_FILE"
  grep -q '\${codename}.noarmor.gpg' "$MODULE_FILE"
  grep -q 'repo_tailscale_url' "$MODULE_FILE"
  grep -q 'repo_tailscale_key_url' "$MODULE_FILE"
  grep -q '^repo_tailscale_url=' "${DEBNAS_ROOT}/config/debnas.conf.default"
  grep -q '^repo_tailscale_key_url=' "${DEBNAS_ROOT}/config/debnas.conf.default"
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

@test "tailscale: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "tailscale: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "tailscale: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "tailscale: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "tailscale: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status tailscale
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan tailscale
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- tailscale 专项 ----------

@test "tailscale: status 区分未安装/未运行/未登录/已登录" {
  local base="dpkg-query() { echo installed; }"
  run _contract_probe status "dpkg-query() { echo not-installed; }"
  [[ "$output" == absent\|* ]]
  run _contract_probe status "$base; systemctl() { return 3; }"
  [[ "$output" == warn\|* ]]
  run _contract_probe status "$base; systemctl() { return 0; }; tailscale() { [[ \"\$1\" == status ]] && printf '{\n  \"BackendState\": \"NeedsLogin\",\n}\n'; }; timeout() { shift; \"\$@\"; }"
  [[ "$output" == partial\|*tailscale\ up* ]]
  run _contract_probe status "$base; systemctl() { return 0; }; tailscale() { if [[ \"\$1\" == status ]]; then printf '  \"BackendState\": \"Running\",\n'; else echo 100.64.0.1; fi; }; timeout() { shift; \"\$@\"; }"
  [[ "$output" == "running|已登录运行中 · 100.64.0.1" ]]
}

@test "tailscale: plan 列出 keyring/源写入、第三方源风险，不含联网动作" {
  run _contract_probe plan "TAILSCALE_SOURCES_DIR='$BATS_TMPDIR'; TAILSCALE_KEYRING_FILE='$BATS_TMPDIR/k.gpg'"
  [[ "$output" == *"write|$BATS_TMPDIR/k.gpg|"* ]]
  [[ "$output" == *"write|$BATS_TMPDIR/tailscale.sources|"*"/var/backups/debnas/"* ]]
  [[ "$output" == *"risk|第三方软件源|"* ]]
  [[ "$output" == *"tailscale up"* ]]
}

# ==================== 后端状态解析（行为） ====================

@test "tailscale: _ts_backend_state 解析 BackendState" {
  local mock="${BATS_TEST_TMPDIR}/mockbin"
  mkdir -p "$mock"
  cat > "${mock}/tailscale" <<'INNEREOF'
#!/bin/sh
printf '{\n  "BackendState": "Running"\n}\n'
INNEREOF
  chmod +x "${mock}/tailscale"
  run env PATH="${mock}:$PATH" bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/tailscale.sh" >/dev/null 2>&1
    _ts_backend_state
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 && "$output" == "Running" ]]
}

@test "tailscale: _ts_backend_state 返回 NeedsLogin" {
  local mock="${BATS_TEST_TMPDIR}/mockbin"
  mkdir -p "$mock"
  cat > "${mock}/tailscale" <<'INNEREOF'
#!/bin/sh
printf '{\n  "BackendState": "NeedsLogin"\n}\n'
INNEREOF
  chmod +x "${mock}/tailscale"
  run env PATH="${mock}:$PATH" bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/tailscale.sh" >/dev/null 2>&1
    _ts_backend_state
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 && "$output" == "NeedsLogin" ]]
}
