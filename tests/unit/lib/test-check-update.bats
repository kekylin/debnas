#!/usr/bin/env bats
# 测试: debnas check-update（只读版本检测）
#   - CLI 接线：子命令路由、帮助文本、未知子命令不受影响
#   - 只读约束：不下载发布包、不持部署锁、不改安装目录
#   - 退出码与结论映射：0 已最新 / 1 有新版本 / 2 检查失败（含原因）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 取出真实的 cmd_check_update（bin/debnas 末尾会执行 main，不能整体 source）
  CHECK_FN=$(sed -n '/^cmd_check_update()/,/^}/p' "${DEBNAS_ROOT}/bin/debnas")
}

# 用桩函数运行真实的 cmd_check_update
# 参数：$1 - 最新版本  $2 - 失败原因（可为空）  $3 - release_check_latest 的返回值
_run_cmd_check_update() {
  local latest="$1" err="${2:-}" want_rc="$3"
  run bash -c '
    set -uo pipefail
    log_info()    { echo "INFO: $*"; }
    log_success() { echo "OK: $*"; }
    log_warning() { echo "WARN: $*"; }
    log_error()   { echo "ERROR: $*"; }
    config_read() { echo "cn"; }
    create_temp_dir() { mktemp -d; }
    _DEBNAS_ROOT="$2"
    DEBNAS_VERSION=v1.0.0
    _stub_latest="$3"; _stub_err="$4"; _stub_rc="$5"
    eval "$1"
    # 措辞由 installer.sh 的 release_check_error_text 提供，这里只验证原因→文案的接线
    release_check_error_text() {
      case "${1:-}" in
        no-key) echo "安装目录缺少发布公钥" ;;
        untrusted) echo "版本指针 LATEST 的签名校验未通过" ;;
        older) echo "远端版本低于当前版本" ;;
        *) echo "无法获取最新版本号" ;;
      esac
    }
    # 桩只用脚本级变量：函数内的 $1/$2 是 release_check_latest 自己的参数
    release_check_latest() {
      _REL_INSTALLED_TAG=v1.0.0
      _REL_LATEST_TAG="$_stub_latest"
      _REL_ERROR="$_stub_err"
      return "$_stub_rc"
    }
    rc=0
    cmd_check_update || rc=$?
    echo "RC=$rc"
  ' _ "$CHECK_FN" "${DEBNAS_ROOT}" "$latest" "$err" "$want_rc"
}

# ==================== CLI 接线 ====================

@test "check-update: bin/debnas 路由到 cmd_check_update" {
  grep -qE '^[[:space:]]*check-update\)' "${DEBNAS_ROOT}/bin/debnas"
  grep -q 'cmd_check_update' "${DEBNAS_ROOT}/bin/debnas"
}

@test "check-update: --help 列出子命令与退出码说明" {
  run bash -c '
    source "$1"/lib/system/args.sh
    print_help
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"check-update"* ]]
  [[ "$output" == *"0=已最新"* && "$output" == *"1=有新版本"* && "$output" == *"2=检查失败"* ]]
}

@test "check-update: 只读实现不下载发布包、不持部署锁、不写安装目录" {
  [[ -n "$CHECK_FN" ]]
  [[ "$CHECK_FN" != *"installer_download_release"* ]]
  [[ "$CHECK_FN" != *"installer_deploy"* ]]
  [[ "$CHECK_FN" != *"deploy_lock"* ]]
  # 只用 release_check_latest 读取版本指针
  [[ "$CHECK_FN" == *"release_check_latest"* ]]
}

# ==================== 退出码与结论 ====================

@test "check-update: 已是最新 → 输出 OK 并返回 0" {
  _run_cmd_check_update v1.0.0 "" 0
  [[ "$status" -eq 0 ]]
  # 版本号带 [INFO] 前缀，不裸行展示
  [[ "$output" == *"INFO: 当前版本：v1.0.0"* ]]
  [[ "$output" == *"INFO: 最新版本：v1.0.0"* ]]
  [[ "$output" == *"已是最新版本"* ]]
  [[ "$output" == *"RC=0"* ]]
}

@test "check-update: 有新版本 → 提示 debnas update 并返回 1" {
  _run_cmd_check_update v1.1.0 "" 1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"当前版本：v1.0.0"* && "$output" == *"最新版本：v1.1.0"* ]]
  [[ "$output" == *"发现新版本：v1.1.0"* && "$output" == *"debnas update"* ]]
  [[ "$output" == *"RC=1"* ]]
}

@test "check-update: 指针验签失败 → 明确报错并返回 2" {
  _run_cmd_check_update "" untrusted 2
  [[ "$output" == *"签名校验未通过"* ]]
  [[ "$output" == *"RC=2"* ]]
}

@test "check-update: 缺公钥 / 网络不可达 / 指针回放 → 返回 2 且原因可区分" {
  _run_cmd_check_update "" no-key 2
  [[ "$output" == *"缺少发布公钥"* && "$output" == *"RC=2"* ]]

  _run_cmd_check_update "" unavailable 2
  [[ "$output" == *"无法获取最新版本号"* && "$output" == *"RC=2"* ]]

  _run_cmd_check_update v0.9.0 older 2
  [[ "$output" == *"低于当前版本"* && "$output" == *"RC=2"* ]]
}

# ==================== 首页"有新版本"提示缓存 ====================

@test "update_check 缓存: 写入后可读、有效期内 fresh、过期 stale、可清除" {
  run bash -c '
    export DEBNAS_UPDATE_CACHE="$2/update-check" DEBNAS_UPDATE_CACHE_TTL=3600
    source "$1"/lib/system/installer.sh
    update_check_cache_write newer v9.9.9
    update_check_cache_read
    echo "state=$_UC_STATE latest=$_UC_LATEST"
    update_check_cache_fresh && echo fresh
    printf "checked_at=100\nlatest=v8.0.0\nstate=newer\n" > "$DEBNAS_UPDATE_CACHE"
    update_check_cache_read
    update_check_cache_fresh || echo stale
    update_check_cache_clear
    [[ -f "$DEBNAS_UPDATE_CACHE" ]] && echo exists || echo cleared
  ' _ "${DEBNAS_ROOT}" "${BATS_TEST_TMPDIR}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"state=newer latest=v9.9.9"* ]]
  [[ "$output" == *"fresh"* && "$output" == *"stale"* ]]
  [[ "$output" == *"cleared"* ]]
}

@test "update_check_refresh_bg: 检查结果写入缓存（newer / latest / error）" {
  run bash -c '
    export DEBNAS_UPDATE_CACHE="$2/update-check" DEBNAS_UPDATE_CACHE_TTL=3600
    source "$1"/lib/system/installer.sh
    create_temp_dir() { mktemp -d; }
    release_check_latest() { _REL_LATEST_TAG=v9.9.9; return 1; }
    update_check_refresh_bg cn /opt/x
    echo "A=$(sed -n "s/^state=//p" "$DEBNAS_UPDATE_CACHE") B=$(sed -n "s/^latest=//p" "$DEBNAS_UPDATE_CACHE")"
    release_check_latest() { _REL_LATEST_TAG=v1.0.0; return 0; }
    update_check_refresh_bg cn /opt/x
    echo "C=$(sed -n "s/^state=//p" "$DEBNAS_UPDATE_CACHE")"
    release_check_latest() { _REL_LATEST_TAG=; return 2; }
    update_check_refresh_bg cn /opt/x
    echo "D=$(sed -n "s/^state=//p" "$DEBNAS_UPDATE_CACHE")"
  ' _ "${DEBNAS_ROOT}" "${BATS_TEST_TMPDIR}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"A=newer B=v9.9.9"* ]]
  [[ "$output" == *"C=latest"* ]]
  [[ "$output" == *"D=error"* ]]
}

@test "update_check_spawn: 后台检查自带锁与短超时，不阻塞首屏" {
  local body
  body=$(sed -n '/^update_check_spawn()/,/^}/p' "${DEBNAS_ROOT}/lib/system/installer.sh")
  [[ -n "$body" ]]
  [[ "$body" == *"flock -n 9"* ]]
  [[ "$body" == *"DEBNAS_FETCH_TIMEOUT=5"* ]]
  [[ "$body" == *"update_check_refresh_bg"* ]]
  [[ "$body" == *"setsid"* ]]
}

@test "update_hint_init: 缓存 newer → 设置提示；latest → 不设置" {
  run bash -c '
    export DEBNAS_UPDATE_CACHE="$2/update-check" DEBNAS_UPDATE_CACHE_TTL=3600
    source "$1"/lib/bootstrap.sh
    eval "$(sed -n "/^update_hint_init()/,/^}/p" "$1/bin/menu.sh")"
    _UI_UPDATE_HINT=""
    printf "checked_at=%s\nlatest=v9.9.9\nstate=newer\n" "$(date +%s)" > "$DEBNAS_UPDATE_CACHE"
    update_hint_init
    echo "HINT=$_UI_UPDATE_HINT"
    printf "checked_at=%s\nlatest=v9.9.9\nstate=latest\n" "$(date +%s)" > "$DEBNAS_UPDATE_CACHE"
    update_hint_init
    echo "HINT2=$_UI_UPDATE_HINT"
  ' _ "${DEBNAS_ROOT}" "${BATS_TEST_TMPDIR}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"HINT=v9.9.9"* ]]
  [[ "$output" == *"HINT2="* ]]
}

# ==================== 面向普通用户的提示语 ====================

@test "release_check_user_text: 四种原因各给一句话结论" {
  run bash -c '
    source "$1"/lib/system/installer.sh
    release_check_user_text no-key
    release_check_user_text untrusted
    release_check_user_text older
    release_check_user_text unavailable
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "${lines[0]}" == *"缺少更新校验信息"* ]]
  [[ "${lines[1]}" == *"更新信息校验未通过"* ]]
  [[ "${lines[2]}" == *"已是最新可用版本"* ]]
  [[ "${lines[3]}" == *"暂时无法连接更新服务器"* ]]
}

@test "installer_fetch: _RELEASE_QUIET=1 时不再提示主备源切换" {
  local mock="${BATS_TEST_TMPDIR}/mockbin"
  mkdir -p "$mock"
  printf '#!/bin/sh\nexit 8\n' > "$mock/wget"
  chmod +x "$mock/wget"

  _fetch_quiet() {
    run bash -c '
      PATH="$2:$PATH"
      source "$1"/lib/system/installer.sh
      log_warning() { echo "WARN: $*"; }
      _RELEASE_QUIET="$4"
      rc=0
      installer_fetch "$3/out" http://a/x http://b/x || rc=$?
      echo "rc=$rc"
    ' _ "${DEBNAS_ROOT}" "$mock" "${BATS_TEST_TMPDIR}" "$1"
  }

  _fetch_quiet 1
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" != *"主源下载失败"* ]]

  _fetch_quiet 0
  [[ "$output" == *"主源下载失败"* ]]
}
