#!/bin/bash
# 功能：交互菜单系统
# 说明：Phase 2 — 方向键导航 + ">" 光标指示 + 局部刷新
# 交互菜单入口

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 部署方案 ====================

declare -a SOLUTION_NAMES=()
declare -a SOLUTION_DISPLAY_NAMES=()

# 加载部署方案（config/solutions/*.list）
load_solutions() {
  SOLUTION_NAMES=()
  SOLUTION_DISPLAY_NAMES=()
  local solutions_dir="${_DEBNAS_ROOT}/config/solutions"
  [[ -d "$solutions_dir" ]] || return 0

  local solution_file name display_name
  for solution_file in "$solutions_dir"/*.list; do
    [[ -f "$solution_file" ]] || continue
    name=$(basename "$solution_file" .list)
    display_name=$(sed -n '1s/^#[[:space:]]*//p' "$solution_file" 2>/dev/null)
    [[ -z "$display_name" ]] && display_name="$name"
    SOLUTION_NAMES+=("$name")
    SOLUTION_DISPLAY_NAMES+=("$display_name")
  done
}

# 执行部署方案（按序逐模块调用 module-runner.sh）
execute_solution() {
  local solution_name="$1"
  local solution_file="${_DEBNAS_ROOT}/config/solutions/${solution_name}.list"

  [[ -f "$solution_file" ]] || {
    log_error "方案文件不存在: $solution_file"
    return 1
  }

  local failed=0 module_name
  # 使用 fd 3 读取方案文件，避免 stdin 被重定向污染子进程
  # （否则交互式模块如 mail-account 的 read 会读到方案文件的下一行模块名）
  while IFS= read -r line <&3; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    module_name="${line#"${line%%[![:space:]]*}"}"
    module_name="${module_name%"${module_name##*[![:space:]]}"}"
    [[ -n "$module_name" ]] || continue

    if ! (unset _DEBNAS_BOOTSTRAPPED; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_fail "模块 \"$module_name\" 执行失败，已中断部署方案"
      failed=1
      break
    fi
  done 3< "$solution_file"

  [[ $failed -eq 0 ]] && log_success "部署完成"
  return $failed
}

# ==================== 自动发现模式菜单 ====================

# 构建当前有效分类列表
declare -a ACTIVE_CATEGORIES=()

build_active_categories() {
  ACTIVE_CATEGORIES=()
  for category in "${CATEGORY_ORDER[@]}"; do
    if [[ "$category" == "${MSG_CAT_DEPLOY}" ]]; then
      # 部署分类：有方案文件即有内容
      [[ ${#SOLUTION_NAMES[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    else
      local -a modules
      mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
      [[ ${#modules[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    fi
  done
}

# 执行自动发现模式选择的模块
execute_auto_modules() {
  local category="$1"
  shift
  local -a selected_modules=("$@")

  for module_name in "${selected_modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    if ! (unset _DEBNAS_BOOTSTRAPPED; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_fail "模块 \"$display_name\" 执行失败，已中断"
      break
    fi
  done
}

# ═══════════════════════════════════════════════════════════════
# Phase 2 新菜单循环 — 方向键导航
# ═══════════════════════════════════════════════════════════════

# 部署方案子菜单（新）
handle_solution_sub_menu() {
  local choice exit_code
  while true; do
    ui_screen_init
    choice=$(UI_MENU_BACK_LABEL="← 返回上级" ui_menu "${MSG_CAT_DEPLOY}" "${SOLUTION_DISPLAY_NAMES[@]}") || {
      exit_code=$?
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) exit 0  ;;   # Q：退出程序
        *)   return 0 ;;
      esac
    }

    execute_solution "${SOLUTION_NAMES[$choice]}"
    sleep 1  # 短暂停留，让用户看到最终结果
  done
}

# 自动发现模式子菜单处理（新）
handle_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  # 构建显示名称数组
  local -a display_names=()
  local module_name display_name
  for module_name in "${modules[@]}"; do
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    display_names+=("$display_name")
  done

  local choice exit_code
  while true; do
    ui_screen_init
    choice=$(UI_MENU_BACK_LABEL="← 返回上级" ui_menu "$category" "${display_names[@]}") || {
      exit_code=$?
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) exit 0  ;;   # Q：退出程序
        *)   return 0 ;;
      esac
    }

    # 执行单个选中模块
    execute_auto_modules "$category" "${modules[$choice]}"
    sleep 1  # 短暂停留，让用户看到最终结果
  done
}

# 主菜单循环（新）
main_menu_loop() {
  build_active_categories

  local choice exit_code
  while true; do
    ui_screen_init
    choice=$(UI_MENU_QUIT=1 ui_menu "" "${ACTIVE_CATEGORIES[@]}") || {
      exit_code=$?
      case $exit_code in
        254) continue ;;   # Esc（主菜单无上级，忽略）
        255) break   ;;   # Q：退出程序
        *)   break   ;;
      esac
    }

    local category="${ACTIVE_CATEGORIES[$choice]}"
    if [[ "$category" == "${MSG_CAT_DEPLOY}" ]]; then
      handle_solution_sub_menu
    else
      handle_auto_sub_menu "$category"
    fi
    # 返回后不清屏 — ui_screen_init 在当前位置重绘
    # 模块执行日志保留在上方回滚缓冲区
  done

  ui_cursor_show
  log_action "用户退出 DebNAS"
  exit 0
}

# ==================== 环境设置 ====================

# 设置临时目录（复用 tempfile.sh 集中管理，不再覆盖 EXIT/INT trap）
setup_environment() {
  init_temp_dir
  _MENU_TMP_DIR=$(create_temp_dir "menu")
}

# ==================== 主入口 ====================

main() {
  ui_screen_clear    # 仅此一次清屏

  setup_environment

  # 系统检查
  if ! verify_system_support 2>/dev/null; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 发现模块并使用自动发现模式
  discover_modules 2>/dev/null
  load_solutions
  main_menu_loop
}

main "$@"
