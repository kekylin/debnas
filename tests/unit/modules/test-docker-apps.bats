#!/usr/bin/env bats
# 测试: modules/docker-apps.sh — 部署容器应用模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/docker-apps.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "docker-apps: @module 为 docker-apps" {
  result=$(parse_meta "module")
  [[ "$result" == "docker-apps" ]]
}

@test "docker-apps: @name 为 部署容器应用" {
  result=$(parse_meta "name")
  [[ "$result" == "部署容器应用" ]]
}

@test "docker-apps: @category 为 容器管理" {
  result=$(parse_meta "category")
  [[ "$result" == "容器管理" ]]
}

@test "docker-apps: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "docker-apps: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "docker-apps: @depends 声明 docker 依赖" {
  result=$(parse_meta "depends")
  [[ "$result" == *"docker"* ]]
}

@test "docker-apps: @depend_modules 声明依赖 docker-ce" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"docker-ce"* ]]
}

# ==================== 语法验证 ====================

@test "docker-apps: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "docker-apps: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "docker-apps: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "docker-apps: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "docker-apps: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "docker-apps: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "docker-apps: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "docker-apps: discover_containers 函数已定义" {
  grep -q '^discover_containers()' "$MODULE_FILE"
}

@test "docker-apps: deploy_container 函数已定义" {
  grep -q '^deploy_container()' "$MODULE_FILE"
}

@test "docker-apps: REQUIRED_CMDS 声明 docker 和 curl 依赖" {
  grep -q 'REQUIRED_CMDS=(docker curl)' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "docker-apps: 定义 COMPOSE_DIR 指向 compose 目录" {
  grep -q 'COMPOSE_DIR=' "$MODULE_FILE"
}

@test "docker-apps: COMPOSE_DIR 不存在时退出 ERROR_GENERAL" {
  grep -A3 'COMPOSE_DIR' "$MODULE_FILE" | grep -q 'ERROR_GENERAL'
}

@test "docker-apps: discover_containers 扫描 compose 目录 .yaml/.yml 文件" {
  sed -n '/^discover_containers()/,/^}/p' "$MODULE_FILE" | grep -q '\*\.yaml'
  sed -n '/^discover_containers()/,/^}/p' "$MODULE_FILE" | grep -q '\*\.yml'
}

@test "docker-apps: 解析 compose 文件 @description 元数据" {
  grep -q '@description' "$MODULE_FILE"
}

@test "docker-apps: 不再解析无人使用的 @category（CONTAINER_CATEGORIES 已删除）" {
  ! grep -q 'CONTAINER_CATEGORIES' "$MODULE_FILE" || false
}

@test "docker-apps: 解析 compose 文件 @require 依赖声明" {
  grep -q '@require' "$MODULE_FILE"
}

@test "docker-apps: deploy_container 使用 _DEPLOY_STACK 环检测" {
  grep -q '_DEPLOY_STACK' "$MODULE_FILE"
}

@test "docker-apps: deploy_container 递归解析 @require 依赖" {
  sed -n '/^deploy_container()/,/^}/p' "$MODULE_FILE" | grep -q 'requires'
}

@test "docker-apps: deploy_container 使用 docker compose up -d" {
  grep -q 'docker compose.*up -d' "$MODULE_FILE"
}

@test "docker-apps: main 非交互模式批量部署所有容器" {
  grep -q 'discover_containers' "$MODULE_FILE"
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

@test "docker-apps: 契约守卫行存在且不再裸调用 main" {
  grep -qF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  ! grep -qE '^main "\$@"[[:space:]]*$' "$MODULE_FILE" || false
}

@test "docker-apps: 定义 module_status 与 module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "docker-apps: module_status 输出一行合法状态且不执行 main/顶层副作用" {
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "docker-apps: module_plan 每行类型合法且不执行 main/顶层副作用" {
  run _contract_probe plan
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_plan_lines "$output"
}

@test "docker-apps: module-runner --probe status/plan 只读探测通过" {
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status docker-apps
  [ "$status" -eq 0 ]
  _assert_status_line "$output"
  run env -u DEBNAS_MODULES_DIR bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan docker-apps
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
}

# ---------- docker-apps 专项：顶层副作用已移入 main（回归） ----------

@test "docker-apps: 顶层不再执行 check_dependencies / compose 目录检查 / discover_containers" {
  # 函数体外（行首无缩进）不得出现这些调用
  ! grep -qE '^(if ! check_dependencies|if \[\[ ! -d "\$COMPOSE_DIR" \]\]|discover_containers[[:space:]]*$)' "$MODULE_FILE" || false
  # 它们都在 main 中
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'check_dependencies'
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -q 'COMPOSE_DIR'
  sed -n '/^main() {/,/^}/p' "$MODULE_FILE" | grep -qE '^[[:space:]]+discover_containers[[:space:]]*$'
}

@test "docker-apps: 缺少 docker/curl 时加载模块不退出（探测零副作用）" {
  # 桩 check_dependencies 返回 1：旧版顶层会直接 exit，探测拿不到输出
  run _contract_probe status
  [ "$status" -eq 0 ]
  [[ "$output" != *MAIN-RAN* ]]
  _assert_status_line "$output"
}

@test "docker-apps: 加载后不填充 CONTAINER_KEYS（discover_containers 未在加载时执行）" {
  run _contract_probe status 'declare -p CONTAINER_KEYS >/dev/null 2>&1 && echo DISCOVERED; true'
  [[ "$output" != *DISCOVERED* ]]
}

@test "docker-apps: plan 端口从 compose 文件读取（短格式/IP/udp/区间/长格式）" {
  local dir="$BATS_TMPDIR/da-compose"
  rm -rf "$dir"; mkdir -p "$dir"
  cat > "$dir/demo.yaml" << 'YAML'
# @name: Demo
services:
  demo:
    image: foo/demo:1
    ports:
      # 9000 已移除
      - "127.0.0.1:8080:80"
      - 53:53/udp
      - '5001:5001'
      - 6000-6002:6000-6002
      - target: 80
        published: 8443
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
YAML
  run _contract_probe plan "COMPOSE_DIR='$dir'; timeout() { shift; \"\$@\"; }; docker() { [[ \"\$1\" == ps ]] && return 0; return 1; }"
  [ "$status" -eq 0 ]
  _assert_plan_lines "$output"
  [[ "$output" == *"service|demo|"* ]]
  [[ "$output" == *"port|8080/tcp 53/udp 5001/tcp 6000-6002/tcp 8443/tcp|"* ]]
  [[ "$output" == *"risk|Demo|挂载 /var/run/docker.sock"* ]]
  [[ "$output" != *"9000"* ]]
  rm -rf "$dir"
}

@test "docker-apps: 已存在的容器不列部署，status 统计运行中" {
  local dir="$BATS_TMPDIR/da-compose2"
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'services:\n  a:\n    image: a\n    ports:\n      - 1234:1234\n' > "$dir/alpha.yaml"
  printf 'services:\n  b:\n    image: b\n' > "$dir/beta.yaml"
  # 桩 timeout 直接执行后续命令，使 docker 走函数桩
  local stub="COMPOSE_DIR='$dir'; timeout() { shift; \"\$@\"; }; docker() { printf 'alpha running\n'; }"
  run _contract_probe plan "$stub"
  [[ "$output" == *"info|Alpha|容器 alpha 已存在"* ]]
  [[ "$output" == *"service|beta|"* ]]
  [[ "$output" != *"1234/tcp"* ]]
  run _contract_probe status "$stub"
  [[ "$output" == "partial|1/2 运行中，未部署：beta" ]]
  rm -rf "$dir"
}

@test "docker-apps: 仓库内 compose 文件的发布端口被 plan 识别" {
  local f
  for f in "${DEBNAS_ROOT}"/compose/*.yaml; do
    [[ -f "$f" ]] || continue
    run _contract_probe plan "_da_host_ports '$f'; exit 0"
    [ "$status" -eq 0 ]
    [[ -n "$output" ]]
    [[ "$output" =~ ^[0-9]+(-[0-9]+)?/(tcp|udp) ]]
  done
}

# ---------- 容器名取 compose 的 container_name（bug 修复：原先假定容器名 == compose 文件名） ----------

@test "docker-apps: _da_parse 读取元数据、镜像、docker.sock 与 container_name" {
  local f="$BATS_TMPDIR/da-parse.yaml"
  cat > "$f" << 'YAML'
# @name: Foo Bar
# @description: d e
# @require: a, b
services:
  x:
    image: "foo/x:1"
    container_name: 'my-x'
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock"
      # 注意：首次访问需要设置密码
  y:
    container_name: yy # 注释
YAML
  run _contract_probe status "_da_parse '$f' da-parse; IFS=' '; echo \"\$DA_NAME|\$DA_DESC|\$DA_REQUIRE|\$DA_IMAGE|\$DA_SOCK|\$DA_NOTE|\${DA_CONTAINERS[*]}\"; exit 0"
  [[ "$output" == "Foo Bar|d e|a, b|foo/x:1|1|首次访问需要设置密码|my-x yy" ]]
  printf 'services:\n  z:\n    image: z\n' > "$f"
  run _contract_probe status "_da_parse '$f' da-parse; echo \"\$DA_NAME|\${DA_CONTAINERS[*]}\"; exit 0"
  [[ "$output" == "Da-parse|da-parse" ]]
  rm -f "$f"
}

@test "docker-apps: 容器名与文件名不同时按 container_name 判断已部署/运行状态" {
  local dir="$BATS_TMPDIR/da-compose3"
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'services:\n  web:\n    image: n\n    container_name: my-nginx\n' > "$dir/nginx.yaml"
  local stub="COMPOSE_DIR='$dir'; timeout() { shift; \"\$@\"; }; docker() { printf 'my-nginx running\nnginx exited\n'; }"
  run _contract_probe status "$stub"
  [[ "$output" == "running|1/1 个应用运行中：nginx" ]]
  run _contract_probe plan "$stub"
  [[ "$output" == *"info|Nginx|容器 my-nginx 已存在，跳过部署"* ]]
  [[ "$output" != *"service|nginx|"* ]]
  local stub2="COMPOSE_DIR='$dir'; timeout() { shift; \"\$@\"; }; docker() { printf 'nginx running\n'; }"
  run _contract_probe status "$stub2"
  [[ "$output" == "absent|未部署：nginx" ]]
  rm -rf "$dir"
}

@test "docker-apps: deploy_container 按 container_name 跳过已存在的容器" {
  local dir="$BATS_TMPDIR/da-compose4"
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'services:\n  web:\n    image: n\n    container_name: my-nginx\n' > "$dir/nginx.yaml"
  run bash -c 'source "$1/lib/bootstrap.sh" >/dev/null 2>&1; DEBNAS_MODULE_ACTION=status source "$2"
    COMPOSE_DIR="$3"; log_info() { echo "I:$*"; }; log_success() { :; }
    docker() { if [[ "$1" == ps ]]; then printf "my-nginx exited\n"; else echo COMPOSE-UP; fi; }
    discover_containers; deploy_container nginx' _ "$DEBNAS_ROOT" "$MODULE_FILE" "$dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"已存在，跳过部署"* ]]
  [[ "$output" != *COMPOSE-UP* ]]
  rm -rf "$dir"
}
