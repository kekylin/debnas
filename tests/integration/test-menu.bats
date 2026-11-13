#!/usr/bin/env bats
# 测试: bin/menu.sh — 交互菜单系统（main_menu_loop + build_active_categories）
# 覆盖 TC-ID: TC-P1-MENU-001~006
# Phase 2: 适配 ui_menu 方向键导航架构（旧 read -r 输入 → ui_menu mock）

# tests/integration/ 比 tests/unit/lib/ 浅一层，common-setup 的默认路径回退不正确。
# 在 setup 中从 BATS_TEST_DIRNAME 重新推导 DEBNAS_ROOT。
load '../helpers/common-setup'

setup() {
  # BATS_TEST_DIRNAME 只有在 setup/test 函数中可用。从 tests/integration/ 往上两级 = 项目根。
  export DEBNAS_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

# 辅助：在 bash -c 子 shell 中插值项目根（避免空格路径问题）
_menu_src() { echo "${DEBNAS_ROOT}/bin/menu.sh"; }

# ==================== TC-P1-MENU-001: Q 退出 ====================

@test "main_menu_loop: Q 退出返回 0（TC-P1-MENU-001）" {
  local src
  src=$(_menu_src)

  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/ui/styles.sh 2>/dev/null
    build_active_categories() { ACTIVE_CATEGORIES=("系统工具"); }
    update_hint_init() { :; }
    ui_screen_init() { :; }
    ui_screen_switch() { :; }
    ui_cursor_show() { :; }
    log_action() { :; }
    create_temp_file() { mktemp; }

    # ui_menu 返回 255（Q 退出）
    ui_menu() { return 255; }

    eval "$(sed -n "/^main_menu_loop()/,/^}/p" "$SRC"/bin/menu.sh)"
    main_menu_loop
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

# ==================== TC-P1-MENU-002: Esc 主菜单忽略后 Q 退出 ====================

@test "main_menu_loop: Esc 在主菜单被忽略后 Q 退出（TC-P1-MENU-002）" {
  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/ui/styles.sh 2>/dev/null
    build_active_categories() { ACTIVE_CATEGORIES=("系统工具"); }
    update_hint_init() { :; }
    ui_screen_init() { :; }
    ui_screen_switch() { :; }
    ui_cursor_show() { :; }
    log_action() { :; }
    create_temp_file() { mktemp; }

    # 用文件计数器（$() 是子 shell，变量修改不持久）
    COUNTER_FILE=$(mktemp)
    echo "0" > "$COUNTER_FILE"
    ui_menu() {
      local count
      count=$(cat "$COUNTER_FILE")
      count=$((count + 1))
      echo "$count" > "$COUNTER_FILE"
      if [[ $count -eq 1 ]]; then
        return 254  # Esc → 主菜单忽略
      else
        return 255  # Q → 退出
      fi
    }

    eval "$(sed -n "/^main_menu_loop()/,/^}/p" "$SRC"/bin/menu.sh)"
    main_menu_loop
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

# ==================== TC-P1-MENU-003: 有效选择分发到 handle_auto_sub_menu ====================

@test "main_menu_loop: 有效选择分发到子菜单（TC-P1-MENU-003）" {
  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/ui/styles.sh 2>/dev/null
    build_active_categories() { ACTIVE_CATEGORIES=("系统工具"); }
    update_hint_init() { :; }
    ui_screen_init() { :; }
    ui_screen_switch() { :; }
    ui_cursor_show() { :; }
    log_action() { :; }
    create_temp_file() { mktemp; }

    # 用文件计数器（$() 是子 shell，变量修改不持久）
    COUNTER_FILE=$(mktemp)
    echo "0" > "$COUNTER_FILE"
    # Phase 2 fix: ui_menu 通过 UI_MENU_RESULT_FILE 返回结果（不再用 $() 捕获 stdout）
    ui_menu() {
      local count
      count=$(cat "$COUNTER_FILE")
      count=$((count + 1))
      echo "$count" > "$COUNTER_FILE"
      if [[ $count -eq 1 ]]; then
        # 模拟选中第一项：写入结果文件
        if [[ -n "${UI_MENU_RESULT_FILE:-}" ]]; then
          echo "0" > "$UI_MENU_RESULT_FILE"
        fi
        return 0
      else
        return 255  # Q 退出
      fi
    }

    _HANDLE_CALLED=0
    handle_auto_sub_menu() { _HANDLE_CALLED=1; echo "_HANDLE_CALLED=1"; }
    handle_solution_sub_menu() { :; }

    eval "$(sed -n "/^main_menu_loop()/,/^}/p" "$SRC"/bin/menu.sh)"
    main_menu_loop
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"_HANDLE_CALLED=1"* ]] || false "handle_auto_sub_menu was not called"
}

# ==================== TC-P1-MENU-004: 非终端 stdin 安全退出 ====================

@test "main_menu_loop: 非终端 stdin 安全退出（TC-P1-MENU-004）" {
  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/ui/styles.sh 2>/dev/null
    build_active_categories() { ACTIVE_CATEGORIES=("系统工具"); }
    update_hint_init() { :; }
    ui_screen_init() { :; }
    ui_screen_switch() { :; }
    ui_cursor_show() { :; }
    log_action() { :; }
    create_temp_file() { mktemp; }

    # 非终端：read_key 返回 ESC，ui_menu 返回 254
    # 主菜单忽略 254（continue），循环 → 第4次返回 255 退出
    COUNTER_FILE=$(mktemp)
    echo "0" > "$COUNTER_FILE"
    ui_menu() {
      local count
      count=$(cat "$COUNTER_FILE")
      count=$((count + 1))
      echo "$count" > "$COUNTER_FILE"
      if [[ $count -le 3 ]]; then
        return 254  # 模拟非终端 stdin（read_key 返回 ESC）
      else
        return 255  # 最终退出
      fi
    }

    eval "$(sed -n "/^main_menu_loop()/,/^}/p" "$SRC"/bin/menu.sh)"
    main_menu_loop < /dev/null
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
}

# ==================== TC-P1-MENU-005: 空分类过滤 ====================

@test "build_active_categories: 空分类被过滤（TC-P1-MENU-005）" {
  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    CATEGORY_ORDER=("类别A" "类别B" "类别C")
    SOLUTION_NAMES=()

    get_modules_by_category() {
      case "$1" in
        "类别A") echo "module_a" ; return 0 ;;
        "类别B") return 0 ;;
        "类别C") echo "module_c1"; echo "module_c2"; return 0 ;;
      esac
    }

    eval "$(sed -n "/^build_active_categories()/,/^}/p" "$SRC"/bin/menu.sh)"

    build_active_categories

    declare -p ACTIVE_CATEGORIES
    printf "COUNT=%d\n" "${#ACTIVE_CATEGORIES[@]}"
    for cat in "${ACTIVE_CATEGORIES[@]}"; do
      printf "CAT=%s\n" "$cat"
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"COUNT=3"* ]]
  [[ "$output" == *"CAT=类别A"* ]]
  [[ "$output" == *"CAT=类别C"* ]]
  [[ "$output" == *"CAT=关于项目"* ]]
  [[ "$output" != *"CAT=类别B"* ]]
}

# ==================== TC-P1-MENU-006: 部署方案分类条件显示 ====================

@test "build_active_categories: 有方案时部署分类出现（TC-P1-MENU-006）" {
  run bash -c '
    set -euo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    CATEGORY_ORDER=("系统工具" "一键部署")
    SOLUTION_NAMES=("nas-basic" "web-server")

    get_modules_by_category() {
      case "$1" in
        "系统工具") echo "tool1" ; return 0 ;;
      esac
    }

    eval "$(sed -n "/^build_active_categories()/,/^}/p" "$SRC"/bin/menu.sh)"

    build_active_categories

    declare -p ACTIVE_CATEGORIES
    printf "COUNT=%d\n" "${#ACTIVE_CATEGORIES[@]}"
    for cat in "${ACTIVE_CATEGORIES[@]}"; do
      printf "CAT=%s\n" "$cat"
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"CAT=一键部署"* ]]
  [[ "$output" == *"CAT=系统工具"* ]]
  [[ "$output" == *"CAT=关于项目"* ]]
}

@test "build_active_categories: 无方案时部署分类不出现" {
  # 注意: build_active_categories 的 for 循环末尾条件为假时
  # （如“一键部署”匹配但 SOLUTION_NAMES 为空），函数返回非零。
  # 此测试不设 set -e，避免该已知返回值触发子 shell 退出。
  run bash -c '
    set -uo pipefail
    export NO_COLOR=1
    SRC="$1"; shift

    CATEGORY_ORDER=("系统工具" "一键部署")
    SOLUTION_NAMES=()

    get_modules_by_category() {
      case "$1" in
        "系统工具") echo "tool1" ; return 0 ;;
      esac
    }

    eval "$(sed -n "/^build_active_categories()/,/^}/p" "$SRC"/bin/menu.sh)"

    build_active_categories

    printf "COUNT=%d\n" "${#ACTIVE_CATEGORIES[@]}"
    for cat in "${ACTIVE_CATEGORIES[@]}"; do
      printf "CAT=%s\n" "$cat"
    done
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"CAT=部署方案"* ]]
  [[ "$output" == *"CAT=系统工具"* ]]
  [[ "$output" == *"CAT=关于项目"* ]]
  [[ "$output" == *"COUNT=2"* ]]
}

# ==================== 关于项目（二级菜单：项目简介 / 检查脚本更新） ====================

@test "show_project_intro: 输出项目简介（含作者/地址/当前版本）" {
  run bash -c '
    eval "$(sed -n "/^show_project_intro()/,/^}/p" "$1"/bin/menu.sh)"
    DEBNAS_VERSION=v9.9.9
    show_project_intro
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"一个将 Debian 系统快速配置成准 NAS 系统的脚本。"* ]]
  [[ "$output" == *"作者：kekylin"* ]]
  [[ "$output" == *"github.com/kekylin/debnas"* ]]
  [[ "$output" == *"当前版本：v9.9.9"* ]]
}

@test "handle_about_sub_menu: 二级菜单为 项目简介 / 检查脚本更新" {
  grep -q '^handle_about_sub_menu()' "${DEBNAS_ROOT}/bin/menu.sh"
  local body
  body=$(sed -n '/^handle_about_sub_menu()/,/^}/p' "${DEBNAS_ROOT}/bin/menu.sh")
  [[ "$body" == *'items=("项目简介" "检查脚本更新")'* ]]
  [[ "$body" == *'ui_menu "关于项目"'* ]]
  [[ "$body" == *'show_project_intro'* ]]
  [[ "$body" == *'handle_script_update'* ]]
}

@test "main_menu_loop: 关于项目进入二级菜单，不再内联打印简介" {
  local body
  body=$(sed -n '/^main_menu_loop()/,/^}/p' "${DEBNAS_ROOT}/bin/menu.sh")
  [[ "$body" == *'handle_about_sub_menu'* ]]
  [[ "$body" != *'handle_about_project'* ]]
}

# 在隔离进程中运行真实的 handle_script_update（打桩网络、日志与更新入口）
# 参数：$1 - release_check_latest 返回码  $2 - 最新版本  $3 - 失败原因  $4 - 1=交互（pty）
_run_script_update() {
  local rc="$1" latest="${2:-}" err="${3:-}" interactive="${4:-0}"
  local root="${BATS_TEST_TMPDIR}/root"
  mkdir -p "$root/bin"
  printf '#!/bin/bash\necho "FAKE_UPDATE $*"\n' > "$root/bin/debnas"
  chmod +x "$root/bin/debnas"

  local fn fnfile harness
  fn=$(sed -n '/^handle_script_update()/,/^}/p' "${DEBNAS_ROOT}/bin/menu.sh")
  fnfile="${BATS_TEST_TMPDIR}/fn-script-update.sh"
  printf '%s\n' "$fn" > "$fnfile"
  harness="${BATS_TEST_TMPDIR}/script-update-h.sh"
  cat > "$harness" <<EOF
set -uo pipefail
source "$fnfile"
log_info() { echo "INFO: \$*"; }; log_success() { echo "OK: \$*"; }
log_warning() { echo "WARN: \$*"; }; log_error() { echo "ERROR: \$*"; }
config_read() { echo "cn"; }
create_temp_dir() { mktemp -d; }
_DEBNAS_ROOT="$root"
DEBNAS_VERSION=v1.0.0
release_check_latest() {
  _REL_INSTALLED_TAG=v1.0.0
  _REL_LATEST_TAG="$latest"
  _REL_ERROR="$err"
  return $rc
}
release_check_user_text() { echo "用户提示:\${1:-}"; }
ui_confirm() { echo 0; }
handle_script_update
EOF

  if [[ "$interactive" == "1" ]]; then
    run script -qec "bash $harness" /dev/null
  else
    run bash "$harness" < /dev/null
  fi
}

@test "handle_script_update: 已是最新版本时不再询问更新" {
  _run_script_update 0 v1.0.0 ""
  [[ "$status" -eq 0 ]]
  # 版本号带状态标识前缀，不裸行展示
  [[ "$output" == *"INFO: 当前版本：v1.0.0"* ]]
  [[ "$output" == *"INFO: 最新版本：v1.0.0"* ]]
  [[ "$output" == *"已是最新版本"* ]]
  [[ "$output" != *"FAKE_UPDATE"* ]]
}

@test "handle_script_update: 检查失败时只给一句话结论，不更新" {
  _run_script_update 2 "" untrusted
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"用户提示:untrusted"* ]]
  [[ "$output" != *"FAKE_UPDATE"* ]]
  # 面向普通用户：不再输出内部诊断
  [[ "$output" != *"主源下载失败"* ]]
  [[ "$output" != *"版本指针"* ]]
}

@test "handle_script_update: 检查期间置静默标志（不输出内部诊断）" {
  local body
  body=$(sed -n '/^handle_script_update()/,/^}/p' "${DEBNAS_ROOT}/bin/menu.sh")
  [[ "$body" == *"_RELEASE_QUIET=1"* ]]
  [[ "$body" == *'_RELEASE_QUIET=0'* ]]
}

@test "handle_script_update: 非交互环境只检查不更新" {
  _run_script_update 1 v1.1.0 ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"最新版本：v1.1.0"* ]]
  [[ "$output" == *"非交互环境"* ]]
  [[ "$output" != *"FAKE_UPDATE"* ]]
}

@test "handle_script_update: 交互确认后调用 debnas update --tag <最新版本>" {
  _run_script_update 1 v1.1.0 "" 1
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"FAKE_UPDATE update --tag v1.1.0"* ]]
}
