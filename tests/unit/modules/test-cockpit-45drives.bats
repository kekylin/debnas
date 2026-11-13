#!/usr/bin/env bats
# 测试: modules/cockpit-45drives.sh — 安装 45Drives 扩展模块 (F-14~F-15)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/cockpit-45drives.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "cockpit-45drives: @module 为 cockpit-45drives" {
  result=$(parse_meta "module")
  [[ "$result" == "cockpit-45drives" ]]
}

@test "cockpit-45drives: @name 为 安装 45Drives 官方插件" {
  result=$(parse_meta "name")
  [[ "$result" == "安装 45Drives 官方插件" ]]
}

@test "cockpit-45drives: @category 为 管理面板" {
  result=$(parse_meta "category")
  [[ "$result" == "管理面板" ]]
}

@test "cockpit-45drives: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "cockpit-45drives: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "cockpit-45drives: @depends 声明依赖 curl" {
  result=$(parse_meta "depends")
  [[ "$result" == *"curl"* ]]
}

@test "cockpit-45drives: @depend_modules 声明依赖 cockpit" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"cockpit"* ]]
}

# ==================== 语法验证 ====================

@test "cockpit-45drives: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "cockpit-45drives: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "cockpit-45drives: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "cockpit-45drives: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "cockpit-45drives: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "cockpit-45drives: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "cockpit-45drives: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "cockpit-45drives: configure_45drives_repo 函数已定义" {
  grep -q '^configure_45drives_repo()' "$MODULE_FILE"
}

@test "cockpit-45drives: install_45drives_components_repo 函数已定义" {
  grep -q '^install_45drives_components_repo()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "cockpit-45drives: 不下载也不执行 45Drives setup 远程脚本" {
  run bash -c "grep -v '^[[:space:]]*#' \"\$1\" | grep -q 'repo.45drives.com/setup'" _ "$MODULE_FILE"
  [[ "$status" -ne 0 ]]
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qE '(^|[[:space:]])(bash|sh)[[:space:]]+"?\$'
}

@test "cockpit-45drives: install_45drives_components_repo 安装 file-sharing/identities" {
  grep -A5 'install_45drives_components_repo()' "$MODULE_FILE" | grep -q 'cockpit-file-sharing'
  grep -A5 'install_45drives_components_repo()' "$MODULE_FILE" | grep -q 'cockpit-identities'
}

@test "cockpit-45drives: 不安装 cockpit-navigator" {
  ! grep -q 'cockpit-navigator' "$MODULE_FILE"
}

# ==================== 唯一共享管理模块（自研 cockpit-shares 已移除） ====================

@test "cockpit-45drives: 不引用已移除的 cockpit-shares" {
  ! grep -q 'cockpit-shares' "$MODULE_FILE"
}

@test "cockpit-45drives: 不再有自研插件二选一逻辑" {
  ! grep -qE '_fd45_ui_choice|ensure_debnas_shares_removed|remove_debnas_shares_plugin_dir|DEBNAS_SHARES_PLUGIN_DIR|file_sharing_ui|file_sharing_nfs' "$MODULE_FILE"
}

@test "cockpit-45drives: 一键方案包含 cockpit-45drives 且不含 cockpit-shares" {
  local f
  for f in "${DEBNAS_ROOT}"/config/solutions/*.list; do
    grep -qx 'cockpit-45drives' "$f"
    ! grep -qx 'cockpit-shares' "$f"
  done
}

@test "cockpit-45drives: main 对 bookworm/trixie 统一使用官方仓库" {
  grep -A15 '^main()' "$MODULE_FILE" | grep -q 'bookworm'
  grep -A15 '^main()' "$MODULE_FILE" | grep -q 'trixie'
  grep -A15 '^main()' "$MODULE_FILE" | grep -q 'configure_45drives_repo'
  grep -A15 '^main()' "$MODULE_FILE" | grep -q 'install_45drives_components_repo'
}

@test "cockpit-45drives: 不包含 Debian 13 手动下载函数" {
  ! grep -q 'install_45drives_components_manual' "$MODULE_FILE"
}

@test "cockpit-45drives: main 不支持的版本返回 ERROR_UNSUPPORTED_OS" {
  grep -A25 '^main()' "$MODULE_FILE" | grep -q 'ERROR_UNSUPPORTED_OS'
}

# ==================== 自写源 + 指纹校验 ====================

@test "cockpit-45drives: 固定 45Drives 公钥主密钥指纹" {
  grep -q '^FD45_GPG_FINGERPRINT="3FBD7E034E80BAF63D5AA9BB9889DBBC731C472B"' "$MODULE_FILE"
}

@test "cockpit-45drives: 公钥经 keyring_install_verified 下载校验（--dearmor），不再自写 curl/gpg" {
  grep -q 'keyring_install_verified "\$key_url" "\$FD45_GPG_FINGERPRINT" "\$FD45_KEYRING_FILE" --dearmor' "$MODULE_FILE"
  ! grep -qE 'gpg .*--show-keys|^[[:space:]]*curl |verify_45drives_gpg_fingerprint|install_45drives_keyring|read_45drives_url' "$MODULE_FILE" || false
  grep -q 'config_get_url repo_45drives_url' "$MODULE_FILE"
}

@test "cockpit-45drives: 公钥安装失败时 main 以 ERROR_DEPENDENCY 退出，且不写源/不装包" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    get_system_codename() { echo trixie; }; config_read() { echo "${3:-}"; }
    log_info() { :; }; log_error() { :; }
    keyring_install_verified() { local IFS=" "; echo "KIV:$*"; return 1; }
    write_file_if_changed() { echo WROTE; }; apt_install_packages() { echo APT; }; config_write() { echo CW; }
    main' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$status" -eq 2 ]]  # ERROR_DEPENDENCY
  [[ "$output" == *"KIV:https://repo.45drives.com/key/gpg.asc 3FBD7E034E80BAF63D5AA9BB9889DBBC731C472B /usr/share/keyrings/45drives-archive-keyring.gpg --dearmor --label 45Drives"* ]]
  [[ "$output" != *WROTE* && "$output" != *CW* ]]
}

@test "cockpit-45drives: DEB822 .sources 使用 Signed-By 指向 keyring" {
  grep -q '45drives.sources' "$MODULE_FILE"
  grep -q '^Signed-By: \${FD45_KEYRING_FILE}' "$MODULE_FILE"
  grep -q '^Components: main' "$MODULE_FILE"
  grep -q '^Architectures: amd64' "$MODULE_FILE"
  grep -q 'FD45_KEYRING_FILE:-/usr/share/keyrings/45drives-archive-keyring.gpg' "$MODULE_FILE"
}

@test "cockpit-45drives: 默认仓库与公钥地址为官方地址" {
  grep -q '^FD45_DEFAULT_REPO_URL="https://repo.45drives.com/enterprise/debian"' "$MODULE_FILE"
  grep -q '^FD45_DEFAULT_KEY_URL="https://repo.45drives.com/key/gpg.asc"' "$MODULE_FILE"
}

@test "cockpit-45drives: 仓库/公钥地址可通过 debnas.conf 配置" {
  grep -q 'repo_45drives_url' "$MODULE_FILE"
  grep -q 'repo_45drives_key_url' "$MODULE_FILE"
  grep -q '^repo_45drives_url=' "${DEBNAS_ROOT}/config/debnas.conf.default"
  grep -q '^repo_45drives_key_url=' "${DEBNAS_ROOT}/config/debnas.conf.default"
}

@test "cockpit-45drives: .sources 通过 write_file_if_changed 写入" {
  grep -q 'write_file_if_changed "\${FD45_SOURCES_DIR}/45drives.sources"' "$MODULE_FILE"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/cockpit-45drives.sh"
PROBE_STATE="${BATS_TMPDIR}/cockpit-45drives-probe-state"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="$PROBE_STATE" DEBNAS_FEATURE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "cockpit-45drives-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "cockpit-45drives-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "cockpit-45drives-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "cockpit-45drives-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$PROBE_STATE" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "cockpit-45drives-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "cockpit-45drives-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "cockpit-45drives-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="$PROBE_STATE" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status cockpit-45drives
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 状态判定（行为） ====================

@test "cockpit-45drives: module_status 区分未安装/部分就绪/已就绪" {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/sources.d"
  : > "$d/sources.d/45drives.sources"
  : > "$d/keyring.gpg"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/cockpit-45drives.sh" >/dev/null 2>&1
    FD45_SOURCES_DIR="$2/sources.d"
    FD45_KEYRING_FILE="$2/keyring.gpg"
    pkg_is_installed() { return 1; }
    module_status

    pkg_is_installed() { return 0; }
    rm -f "$2/sources.d/45drives.sources"
    module_status

    : > "$2/sources.d/45drives.sources"
    module_status
  ' _ "${DEBNAS_ROOT}" "$d"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"absent|未安装 45Drives 官方插件"* ]]
  [[ "$output" == *"partial|45Drives 插件部分就绪"*"45drives.sources"* ]]
  [[ "$output" == *"applied|cockpit-file-sharing + cockpit-identities 已安装"* ]]
}
