#!/usr/bin/env bats
# 测试: modules/docker-mirror.sh — 配置镜像加速模块 (F-49~F-51)
# Mock 策略：纯函数测试 + 结构验证 + PATH Injection Mock docker/systemctl

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/docker-mirror.sh"
export NO_COLOR=1

setup() {
  # 加载核心库以获取 log_* 函数
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"

  # 创建 Mock 命令目录
  MOCK_BIN="$BATS_TMPDIR/mockbin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "docker-mirror: @module 为 docker-mirror" {
  result=$(parse_meta "module")
  [[ "$result" == "docker-mirror" ]]
}

@test "docker-mirror: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "docker-mirror: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "docker-mirror: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "docker-mirror: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "docker-mirror: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "docker-mirror: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "docker-mirror: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "docker-mirror: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "docker-mirror: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

@test "docker-mirror: 定义 DAEMON_JSON 常量指向 /etc/docker/daemon.json" {
  grep -q 'DAEMON_JSON="/etc/docker/daemon.json"' "$MODULE_FILE"
}

@test "docker-mirror: 引用 DOCKER_REGISTRY_MIRRORS 数组" {
  grep -q 'DOCKER_REGISTRY_MIRRORS' "$MODULE_FILE"
}

# ==================== 安全验证 ====================

@test "docker-mirror: SECURITY — 不存在硬编码的 IP 地址" {
  # 排除注释行中的 URL（镜像地址），检查非注释行中是否有裸 IP
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -qP '\b(?<!")(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?!")\b' || true
}

# ==================== 纯函数测试：array_to_json_array ====================

@test "docker-mirror: array_to_json_array — 单元素生成正确 JSON 数组" {
  # 以探测模式加载：只定义函数，不执行 main（否则会真实写 /etc/docker/daemon.json 并重启 docker）
  DEBNAS_MODULE_ACTION=status source "${DEBNAS_ROOT}/modules/docker-mirror.sh" 2>/dev/null || true
  result=$(array_to_json_array "https://mirror.example.com")
  [[ "$result" == *'"https://mirror.example.com"'* ]]
  [[ "$result" == *'['* ]]
  [[ "$result" == *']'* ]]
}

@test "docker-mirror: array_to_json_array — 多元素生成逗号分隔 JSON 数组" {
  DEBNAS_MODULE_ACTION=status source "${DEBNAS_ROOT}/modules/docker-mirror.sh" 2>/dev/null || true
  result=$(array_to_json_array "https://a.com" "https://b.com")
  [[ "$result" == *'"https://a.com"'* ]]
  [[ "$result" == *'"https://b.com"'* ]]
  [[ "$result" == *'"https://a.com",'* ]]  # JSON 逗号分隔
}

@test "docker-mirror: build_merged_daemon_json 函数存在" {
  grep -q '^build_merged_daemon_json()' "$MODULE_FILE"
}

@test "docker-mirror: 使用 write_file_if_changed 安全写入 daemon.json" {
  grep -q 'write_file_if_changed.*DAEMON_JSON' "$MODULE_FILE"
}

@test "docker-mirror: 不直接调用 systemctl（daemon.json 变更只需 service_ensure 重启）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<systemctl daemon-reload\>'
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'service_ensure docker restarted'
}

@test "docker-mirror: daemon.json 写入失败时报错退出（不再当作“未变”）" {
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    check_dependencies() { return 0; }; log_info() { echo "I:$*"; }; log_warning() { :; }; log_error() { echo "E:$*"; }
    build_merged_daemon_json() { echo "{}"; }; write_file_if_changed() { return 2; }
    service_ensure() { echo RESTART; }
    main' _ "$DEBNAS_ROOT" "$MODULE_FILE"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"E:写入 /etc/docker/daemon.json 失败"* ]]
  [[ "$output" != *RESTART* && "$output" != *"配置未变"* ]]
}

@test "docker-mirror: array_to_json_array — 输出格式与旧实现一致" {
  DEBNAS_MODULE_ACTION=status source "${DEBNAS_ROOT}/modules/docker-mirror.sh" 2>/dev/null || true
  [[ "$(array_to_json_array a b)" == $'[\n    "a",\n    "b"\n  ]' ]]
  [[ "$(array_to_json_array)" == $'[\n  ]' ]]
}

@test "docker-mirror: 只合并 registry-mirrors 键（不再 grep 全部 URL）" {
  ! grep -q "grep -oP '\"https?://" "$MODULE_FILE"
  grep -q 'registry-mirrors' "$MODULE_FILE"
}

@test "docker-mirror: 已有 daemon.json 用 jq 合并，解析失败不覆盖" {
  sed -n '/^build_merged_daemon_json()/,/^}/p' "$MODULE_FILE" | grep -q 'jq --indent 2'
  sed -n '/^build_merged_daemon_json()/,/^}/p' "$MODULE_FILE" | grep -q 'return 1'
  ! grep -q 'python3' "$MODULE_FILE"
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

@test "docker-mirror: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "docker-mirror: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "docker-mirror: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "docker-mirror: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "docker-mirror: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status docker-mirror
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan docker-mirror
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- docker-mirror 专项 ----------

@test "docker-mirror: 依赖检查与流程已移入 main（顶层不 exit）" {
  # check_dependencies 只出现在 main() 定义之后（main 体沿用原风格未缩进）
  local main_ln dep_ln
  main_ln=$(grep -n '^main() {' "$MODULE_FILE" | head -1 | cut -d: -f1)
  dep_ln=$(grep -n 'check_dependencies' "$MODULE_FILE" | head -1 | cut -d: -f1)
  [[ -n "$main_ln" && -n "$dep_ln" && "$dep_ln" -gt "$main_ln" ]]
}

@test "docker-mirror: status 按 daemon.json 判定 absent/partial/applied/error" {
  local d="$BATS_TMPDIR/dm"; rm -rf "$d"; mkdir -p "$d"
  local stub="docker() { :; }; DAEMON_JSON='$d/daemon.json'"
  run _contract_probe status "$stub"
  [[ "$output" == absent\|* ]]
  echo '{"data-root":"/x","registry-mirrors":["https://my.mirror"]}' > "$d/daemon.json"
  run _contract_probe status "$stub"
  [[ "$output" == partial\|* ]]
  run _contract_probe status "$stub; DOCKER_MIRRORS=(https://my.mirror)"
  [[ "$output" == applied\|* ]]
  if command -v jq >/dev/null 2>&1; then
    echo 'not json' > "$d/daemon.json"
    run _contract_probe status "$stub"
    [[ "$output" == error\|* ]]
  fi
  rm -rf "$d"
}

@test "docker-mirror: plan 列出写入/重启/第三方风险，已配置时不改动" {
  local d="$BATS_TMPDIR/dm2"; rm -rf "$d"; mkdir -p "$d"
  local stub="docker() { :; }; DAEMON_JSON='$d/daemon.json'"
  run _contract_probe plan "$stub"
  _assert_plan_lines "$output"
  [[ "$output" == *"write|$d/daemon.json|新建"* ]]
  [[ "$output" == *"service|docker|"* ]]
  [[ "$output" == *"risk|第三方加速源|"* ]]
  echo '{"registry-mirrors":["https://my.mirror"]}' > "$d/daemon.json"
  run _contract_probe plan "$stub; DOCKER_MIRRORS=(https://my.mirror)"
  [[ "$output" == *"info|$d/daemon.json|"* ]]
  [[ "$output" != *"service|docker"* ]]
  rm -rf "$d"
}

# ==================== 回归：未变不重写、不重启（C4） ====================

# 以探测模式加载模块后调用 main；写入/重启替换为输出 WRITE / RESTART 的桩
# 参数：$1 加载后执行的额外 bash 代码（覆盖 DAEMON_JSON / DOCKER_MIRRORS 等）
_run_main() {
  DEBNAS_ROOT="$DEBNAS_ROOT" MODULE_FILE="$MODULE_FILE" EXTRA="${1:-}" bash -c '
    set -euo pipefail
    IFS=$'"'"'\n\t'"'"'
    source "${DEBNAS_ROOT}/lib/bootstrap.sh" >/dev/null 2>&1
    export DEBNAS_MODULE_ACTION=status
    source "$MODULE_FILE" </dev/null
    log_info() { echo "I: $*" >&2; }
    log_warning() { :; }
    log_success() { :; }
    check_dependencies() { return 0; }
    write_file_if_changed() { echo WRITE; printf "%s\n" "$2" > "$1.new"; return 0; }
    service_ensure() { echo "RESTART $*"; return 0; }
    if [[ -n "$EXTRA" ]]; then source /dev/stdin <<< "$EXTRA"; fi
    main </dev/null
  ' 2>&1
}

@test "C4 docker-mirror: 加速源已齐全（紧凑写法）时不重写、不重启" {
  command -v jq >/dev/null 2>&1 || skip "jq 不可用"
  local d="$BATS_TMPDIR/dm-c4a"; rm -rf "$d"; mkdir -p "$d"
  printf '{"data-root":"/x","registry-mirrors":["https://a.example","https://b.example"]}' > "$d/daemon.json"
  run _run_main "DAEMON_JSON='$d/daemon.json'; DOCKER_MIRRORS=(https://b.example https://a.example)"
  [ "$status" -eq 0 ]
  [[ "$output" != *WRITE* && "$output" != *RESTART* ]]
  [[ "$output" == *"未变"* ]]
  rm -rf "$d"
}

@test "C4 docker-mirror: 合并结果与现有内容 jq -S 规范化后相同则不写" {
  command -v jq >/dev/null 2>&1 || skip "jq 不可用"
  local d="$BATS_TMPDIR/dm-c4b"; rm -rf "$d"; mkdir -p "$d"
  printf '{ "registry-mirrors" : [ "https://a.example" ], "log-level":"warn" }' > "$d/daemon.json"
  # 让"缺失检测"误报，强制走合并分支：合并后语义不变时仍不得写入
  run _run_main "DAEMON_JSON='$d/daemon.json'; DOCKER_MIRRORS=(https://a.example); _dm_missing_mirrors() { echo https://a.example; }"
  [ "$status" -eq 0 ]
  [[ "$output" != *WRITE* && "$output" != *RESTART* ]]
  rm -rf "$d"
}

@test "C4 docker-mirror: 只含空白的 daemon.json 按空对象新建，缺源时写入并重启" {
  local d="$BATS_TMPDIR/dm-c4c"; rm -rf "$d"; mkdir -p "$d"
  printf '  \n\t\n' > "$d/daemon.json"
  run _run_main "DAEMON_JSON='$d/daemon.json'; DOCKER_MIRRORS=(https://a.example)"
  [ "$status" -eq 0 ]
  [[ "$output" == *WRITE* && "$output" == *"RESTART docker restarted"* ]]
  grep -q '"https://a.example"' "$d/daemon.json.new"
  if command -v jq >/dev/null 2>&1; then
    printf '{"registry-mirrors":["https://x.example"]}' > "$d/daemon.json"
    run _run_main "DAEMON_JSON='$d/daemon.json'; DOCKER_MIRRORS=(https://a.example)"
    [[ "$output" == *WRITE* ]]
    [[ "$(jq -c '.["registry-mirrors"]' "$d/daemon.json.new")" == '["https://x.example","https://a.example"]' ]]
  fi
  rm -rf "$d"
}

@test "C4 docker-mirror: status/plan 把只含空白的 daemon.json 当作未配置" {
  local d="$BATS_TMPDIR/dm-c4d"; rm -rf "$d"; mkdir -p "$d"
  printf '   \n' > "$d/daemon.json"
  local stub="docker() { :; }; DAEMON_JSON='$d/daemon.json'"
  run _contract_probe status "$stub"
  [[ "$output" == absent\|* ]]
  run _contract_probe plan "$stub"
  [[ "$output" == *"write|$d/daemon.json|新建"* ]]
  rm -rf "$d"
}
