#!/usr/bin/env bats
# 测试: modules/sources.sh — 配置 APT 软件源模块 (F-01~F-04)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）
# 注：此模块已有集成测试 (tests/integration/test-sources.bats)，此为补充单元覆盖

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/sources.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "sources: @module 为 sources" {
  result=$(parse_meta "module")
  [[ "$result" == "sources" ]]
}

@test "sources: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "sources: @category 为 基础系统" {
  result=$(parse_meta "category")
  [[ "$result" == "基础系统" ]]
}

@test "sources: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "sources: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "sources: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "sources: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "sources: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "sources: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "sources: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "sources: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "sources: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "sources: probe_mirror 函数已定义" {
  grep -q '^probe_mirror()' "$MODULE_FILE"
}

@test "sources: detect_best_mirror 函数已定义" {
  grep -q '^detect_best_mirror()' "$MODULE_FILE"
}

@test "sources: 无调用方的 backup_config_files / _sources_os_field 已删除，系统代号用公共函数" {
  ! grep -qE '^(backup_config_files|_sources_os_field)\(\)' "$MODULE_FILE" || false
  ! grep -q '\. /etc/os-release' "$MODULE_FILE" || false
  sed -n '/^module_plan()/,/^}/p' "$MODULE_FILE" | grep -q '_get_os_id'
}

@test "sources: debian.sources 写入失败时报错返回（不再当作“未变更”）" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    verify_debian_12_13_support() { return 0; }; detect_best_mirror() { echo https://m.example; }
    log_success() { :; }; log_info() { echo "I:$*"; }; log_error() { echo "E:$*"; }
    write_file_if_changed() { return 2; }; _backup_file() { echo BACKUP; }; update_package_lists() { echo UPDATE; }
    main' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"E:写入 /etc/apt/sources.list.d/debian.sources 失败"* ]]
  [[ "$output" != *BACKUP* && "$output" != *UPDATE* && "$output" != *"源未变更"* ]]
}

@test "sources: build_deb822_content 函数已定义" {
  grep -q '^build_deb822_content()' "$MODULE_FILE"
}

@test "sources: update_package_lists 函数已定义" {
  grep -q '^update_package_lists()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "sources: DEB822_PATH 常量指向 sources.list.d" {
  grep -q 'DEB822_PATH=.*sources.list.d' "$MODULE_FILE"
}

@test "sources: TRADITIONAL_PATH 常量指向 sources.list" {
  grep -q 'TRADITIONAL_PATH=.*sources.list' "$MODULE_FILE"
}

@test "sources: build_deb822_content 包含 DEB822 格式 Types/URIs/Suites" {
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'Types:'
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'URIs:'
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'Suites:'
}

@test "sources: 使用 write_file_if_changed 实现幂等写入" {
  grep -q 'write_file_if_changed' "$MODULE_FILE"
}

@test "sources: 引用 APT_MIRRORS 数组选择镜像" {
  grep -q 'APT_MIRRORS' "$MODULE_FILE"
}

@test "sources: detect_best_mirror 有官方源回退逻辑" {
  grep -q 'APT_OFFICIAL_MIRROR' "$MODULE_FILE"
}

@test "sources: main 中调用 verify_debian_12_13_support" {
  sed -n '/^main()/,/^}/p' "$MODULE_FILE" | grep -q 'verify_debian_12_13_support'
}

@test "sources: main 中调用 apt_update_safe" {
  grep -q 'apt_update_safe' "$MODULE_FILE"
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

@test "sources: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "sources: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "sources: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "sources: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "sources: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status sources
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan sources
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- sources 专项 ----------

@test "sources: 顶层不再输出日志（wget/curl 检测移入 main）" {
  ! grep -qE '^if ! command -v wget' "$MODULE_FILE" || false
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q '_sources_detect_probe_tool'
}

@test "sources: status 识别 DEB822 镜像、传统源与套件不符" {
  local d="$BATS_TMPDIR/src"; rm -rf "$d"; mkdir -p "$d"
  local cn
  cn=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: %s %s-updates\n' "$cn" "$cn" > "$d/debian.sources"
  printf 'deb http://deb.debian.org/debian %s main\n' "$cn" > "$d/sources.list"
  local stub="DEB822_PATH='$d/debian.sources'; TRADITIONAL_PATH='$d/none.list'"
  run _contract_probe status "$stub"
  [[ "$output" == applied\|*Debian* ]]
  run _contract_probe status "DEB822_PATH='$d/debian.sources'; TRADITIONAL_PATH='$d/sources.list'"
  [[ "$output" == partial\|* ]]
  run _contract_probe status "DEB822_PATH='$d/none'; TRADITIONAL_PATH='$d/sources.list'"
  [[ "$output" == absent\|* ]]
  printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: nosuch\n' > "$d/debian.sources"
  run _contract_probe status "$stub"
  [[ "$output" == warn\|* ]]
  rm -rf "$d"
}

@test "sources: plan 含替换系统源风险与 debian.sources 写入（备份说明）" {
  run _contract_probe plan
  if grep -q '^ID=debian' /etc/os-release 2>/dev/null; then
    [[ "$output" == *"write|/etc/apt/sources.list.d/debian.sources|"*"/var/backups/debnas/"* ]]
    [[ "$output" == *"risk|APT 软件源|"* ]]
  fi
}

# ==================== 回归：sid 区分与 apt update 失败恢复（C5） ====================

# 提取 _sources_suite_kind + build_deb822_content，在给定 debian_version / 现有源下生成内容
# 参数：$1 代号，$2 debian_version 内容，$3 现有 debian.sources 内容（可空）
_gen_deb822() {
  local d="$BATS_TEST_TMPDIR"
  printf '%s\n' "$2" > "$d/debian_version"
  printf '%s' "$3" > "$d/debian.sources"
  CODENAME="$1" SOURCES_DEBIAN_VERSION_FILE="$d/debian_version" DEB822_PATH="$d/debian.sources" TRADITIONAL_PATH="$d/none" \
    bash -c 'eval "$(sed -n "/^_sources_suite_kind()/,/^}/p;/^build_deb822_content()/,/^}/p" "$1")"; build_deb822_content https://m' _ "$MODULE_FILE"
}

@test "C5 sources: debian_version 为 */sid 且现有源指向 sid 时按 sid 生成（无 -updates/-security）" {
  run _gen_deb822 forky "forky/sid" $'Types: deb\nURIs: https://x/debian\nSuites: sid\n'
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Suites: sid"$'\n'* ]]
  [[ "$output" != *"forky"* && "$output" != *"debian-security"* ]]
  run _gen_deb822 forky "forky/sid" $'deb http://x/debian unstable main\n'
  [[ "$output" == *"Suites: sid"$'\n'* ]]
}

@test "C5 sources: debian_version 为 */sid 但现有源是 testing 代号时按 testing 生成" {
  run _gen_deb822 forky "forky/sid" $'Types: deb\nURIs: https://x/debian\nSuites: forky forky-updates\n'
  [[ "$output" == *"Suites: forky forky-updates"$'\n'* ]]
  [[ "$output" != *"backports"* ]]
  [[ "$output" == *"forky-security"* ]]
}

@test "C5 sources: 正式版（debian_version 为数字）照常含 -updates/-backports/-security" {
  run _gen_deb822 trixie "13.1" ""
  [[ "$output" == *"Suites: trixie trixie-updates trixie-backports"$'\n'* ]]
  [[ "$output" == *"trixie-security"* ]]
}

# 在临时目录模拟一次运行：集中备份目录里有运行前的两个文件，当前为新写入的内容
_restore_env() {
  local d="$BATS_TEST_TMPDIR"
  R="$d/root"; mkdir -p "$R/etc/apt/sources.list.d"
  DEBNAS_BACKUP_ROOT="$d/backups"; DEBNAS_BACKUP_RUN_ID="run1"
  DEB822_PATH="$R/etc/apt/sources.list.d/debian.sources"
  TRADITIONAL_PATH="$R/etc/apt/sources.list"
  log_error() { echo "E: $*"; }
  log_info() { :; }
  source "${DEBNAS_ROOT}/lib/core/constants.sh" 2>/dev/null || true
  eval "$(sed -n '/^write_file_if_changed()/,/^}/p' "${DEBNAS_ROOT}/lib/system/utils.sh")"
  eval "$(sed -n '/^_sources_restore_backup()/,/^}/p' "$MODULE_FILE")"
}

@test "C5 sources: apt update 失败时从集中备份恢复 debian.sources 与 sources.list" {
  _restore_env
  mkdir -p "$DEBNAS_BACKUP_ROOT/run1$(dirname "$DEB822_PATH")"
  printf 'OLD822\n' > "$DEBNAS_BACKUP_ROOT/run1$DEB822_PATH"
  printf 'deb http://old/debian trixie main\n' > "$DEBNAS_BACKUP_ROOT/run1$TRADITIONAL_PATH"
  printf 'NEW822\n' > "$DEB822_PATH"
  _SOURCES_DEB822_EXISTED=1; _SOURCES_LEGACY_MOVED=1; _SOURCES_LEGACY_BAK=""
  run _sources_restore_backup
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$DEB822_PATH")" == "OLD822" ]]
  [[ "$(cat "$TRADITIONAL_PATH")" == "deb http://old/debian trixie main" ]]
}

@test "C5 sources: 运行前没有 debian.sources 时删除新建文件；sources.list 从同目录 .bak 改回" {
  _restore_env
  printf 'NEW822\n' > "$DEB822_PATH"
  printf 'LEGACY\n' > "$TRADITIONAL_PATH.20261110.bak"
  _SOURCES_DEB822_EXISTED=0; _SOURCES_LEGACY_MOVED=1; _SOURCES_LEGACY_BAK="$TRADITIONAL_PATH.20261110.bak"
  run _sources_restore_backup
  [[ "$status" -eq 0 ]]
  [[ ! -e "$DEB822_PATH" ]]
  [[ "$(cat "$TRADITIONAL_PATH")" == "LEGACY" && ! -e "$TRADITIONAL_PATH.20261110.bak" ]]
}

@test "C5 sources: 有原文件但找不到备份时报错返回 1" {
  _restore_env
  printf 'NEW822\n' > "$DEB822_PATH"
  _SOURCES_DEB822_EXISTED=1; _SOURCES_LEGACY_MOVED=0; _SOURCES_LEGACY_BAK=""
  run _sources_restore_backup
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"无法自动恢复"* ]]
}

@test "C5 sources: main 在 apt update 失败分支调用恢复并报错，写入前记录 debian.sources 是否存在" {
  local body
  body=$(sed -n '/^main() {/,/^}/p' "$MODULE_FILE")
  [[ "$body" == *'if _sources_restore_backup; then'* ]]
  [[ "$body" == *'log_error "apt update 失败，已从备份恢复原软件源'* ]]
  [[ "$body" == *'[[ -f "$DEB822_PATH" ]] && _SOURCES_DEB822_EXISTED=1'* ]]
}

# ==================== DEB822 / 传统源解析（行为） ====================

@test "sources: _sources_deb822_field 跳过注释并读取首个字段" {
  local d
  d=$(mktemp -d)
  cat > "$d/debian.sources" <<'INNEREOF'
Types: deb
# URIs: http://comment.example/debian
URIs: http://mirror.example/debian
Suites: bookworm
INNEREOF
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/sources.sh" >/dev/null 2>&1
    _sources_deb822_field uris "$2"
  ' _ "${DEBNAS_ROOT}" "$d/debian.sources"
  rm -rf "$d"
  [[ "$status" -eq 0 && "$output" == "http://mirror.example/debian" ]]
}

@test "sources: _sources_legacy_uri 取第一条 deb 行的 URI" {
  local d
  d=$(mktemp -d)
  cat > "$d/sources.list" <<'INNEREOF'
# deb http://comment.example/debian bookworm main
deb http://first.example/debian bookworm main
deb-src http://src.example/debian bookworm main
deb [arch=amd64] http://second.example/debian bookworm main
INNEREOF
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/sources.sh" >/dev/null 2>&1
    TRADITIONAL_PATH="$2"
    _sources_legacy_uri
  ' _ "${DEBNAS_ROOT}" "$d/sources.list"
  rm -rf "$d"
  [[ "$status" -eq 0 && "$output" == "http://first.example/debian" ]]
}

@test "sources: build_deb822_content 为 stable 生成标准源与安全源" {
  local d
  d=$(mktemp -d)
  printf '12.5\n' > "$d/debian_version"
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/sources.sh" >/dev/null 2>&1
    CODENAME=bookworm
    SOURCES_DEBIAN_VERSION_FILE="$2"
    DEB822_PATH="$2.none"; TRADITIONAL_PATH="$2.none2"
    build_deb822_content "https://m.example"
  ' _ "${DEBNAS_ROOT}" "$d/debian_version"
  rm -rf "$d"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"URIs: https://m.example/debian"* ]]
  [[ "$output" == *"Suites: bookworm bookworm-updates bookworm-backports"* ]]
  [[ "$output" == *"URIs: https://m.example/debian-security"* ]]
  [[ "$output" == *"Suites: bookworm-security"* ]]
}

@test "sources: build_deb822_content 为 sid 只生成 sid 源" {
  run bash -c '
    DEBNAS_MODULE_ACTION=status
    source "$1/modules/sources.sh" >/dev/null 2>&1
    CODENAME=sid
    build_deb822_content "https://m.example"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Suites: sid"* ]]
  [[ "$output" != *"Security Repository"* ]]
  [[ "$output" != *"sid-security"* ]]
}
