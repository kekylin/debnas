#!/bin/bash
# 功能：交互菜单系统
# 说明：Phase 2 — 方向键导航 + ">" 光标指示 + 局部刷新
# 交互菜单入口

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "${_DEBNAS_SCRIPT%/*}/.." && pwd)"  # readlink -f 输出绝对路径，参数展开取目录

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# 方案 A 仪表盘（仅交互菜单使用，不放进 bootstrap，避免拖慢每个模块的加载）
source "${_DEBNAS_ROOT}/lib/ui/textwidth.sh"
source "${_DEBNAS_ROOT}/lib/ui/sysinfo.sh"
source "${_DEBNAS_ROOT}/lib/ui/dashboard.sh"

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

    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_error "模块 \"$module_name\" 执行失败，已中断部署方案"
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
    if [[ "$category" == "一键部署" ]]; then
      # 部署分类：有方案文件即有内容
      [[ ${#SOLUTION_NAMES[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    else
      local -a modules
      mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
      [[ ${#modules[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    fi
  done
  ACTIVE_CATEGORIES+=("关于项目")
  return 0  # 确保函数始终返回 0（避免 set -e 下因最后一个 [[ 失败而退出）
}

# 执行自动发现模式选择的模块
execute_auto_modules() {
  local category="$1"
  shift
  local -a selected_modules=("$@")

  for module_name in "${selected_modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_error "模块 \"$display_name\" 执行失败，已中断"
      break
    fi
  done
}

# ═══════════════════════════════════════════════════════════════
# Phase 2 新菜单循环 — 方向键导航
# ═══════════════════════════════════════════════════════════════

# 关于项目：直接打印概况后返回一级菜单
handle_about_project() {
  local separator
  separator=$(printf '%*s' 46 '' | tr ' ' '-')
  printf '\n'
  printf '%s\n' "$separator"
  printf '\n'
  printf '    %s\n' "一个将 Debian 系统快速配置成准 NAS 系统的脚本。"
  printf '\n'
  printf '    作者：%b%s%b\n' "$COLOR_DIM" "kekylin" "$COLOR_RESET"
  printf '    地址：%b%s%b\n' "$COLOR_DIM" "https://github.com/kekylin/debnas" "$COLOR_RESET"
  printf '\n'
  printf '%s\n' "$separator"
  printf '\n'
}

# 部署方案子菜单（新）
handle_solution_sub_menu() {
  ui_screen_switch  # 清 L1 菜单区 + 渲染 L2 Header
  # 计算旧 L2 区域总行数（Header + 面包屑 + 菜单项 + 底部标签）
  local _hdr_h=4 _bc_lines=1 _ftr_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && { _hdr_h=3; _bc_lines=1; }
  local _old_area=$((_hdr_h + _bc_lines + ${#SOLUTION_DISPLAY_NAMES[@]} + _ftr_lines))

  local choice exit_code menu_result
  while true; do
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "一键部署" "${SOLUTION_DISPLAY_NAMES[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) ui_cursor_show; log_info "用户退出 DebNAS"; exit 0  ;;
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    # 清除旧菜单 → 打印快照（留在 scrollback）→ 模块输出追加在快照下方
    ui_clear_menu_area "$_old_area"
    declare -f _ui_print_menu_snapshot >/dev/null 2>&1 && _ui_print_menu_snapshot

    # 方案失败时 execute_solution 返回 1（已输出错误），不能让 set -e 直接退出整个菜单
    execute_solution "${SOLUTION_NAMES[$choice]}" || true

    # 在日志末尾重绘 Header + L2 菜单
    ui_screen_init
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

  local choice exit_code menu_result
  ui_screen_switch  # 清 L1 菜单区 + 渲染 L2 Header
  # 计算旧 L2 区域总行数（Header + 面包屑 + 菜单项 + 底部标签）
  local _hdr_h=4 _bc_lines=1 _ftr_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && { _hdr_h=3; _bc_lines=1; }
  local _old_area=$((_hdr_h + _bc_lines + ${#modules[@]} + _ftr_lines))

  while true; do
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "$category" "${display_names[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) ui_cursor_show; log_info "用户退出 DebNAS"; exit 0  ;;
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    # 清除旧菜单 → 打印快照（留在 scrollback）→ 模块输出追加在快照下方
    ui_clear_menu_area "$_old_area"
    declare -f _ui_print_menu_snapshot >/dev/null 2>&1 && _ui_print_menu_snapshot

    # 执行单个选中模块
    execute_auto_modules "$category" "${modules[$choice]}"

    # 在日志末尾重绘 Header + L2 菜单
    ui_screen_init
  done
}

# 主菜单循环（新）
main_menu_loop() {
  # Ctrl+C 在菜单导航中静默忽略（子进程中由 module-runner 自行处理）
  trap ':' INT

  build_active_categories

  # 空分类保护：无模块也无方案时直接退出
  if [[ ${#ACTIVE_CATEGORIES[@]} -eq 0 ]]; then
    log_error "未发现任何可用模块，请检查 modules/ 目录"
    ui_cursor_show
    exit "${ERROR_MODULE_NOT_FOUND:-1}"
  fi

  local choice exit_code menu_result preserve_output=0
  local first_entry=1
  while true; do
    if [[ $first_entry -eq 1 ]]; then
      ui_screen_init    # 首次：无旧菜单需清除
      first_entry=0
    elif [[ $preserve_output -eq 1 ]]; then
      ui_screen_init    # 关于项目后：菜单追加在简介下方，不清除已打印内容
      preserve_output=0
    else
      ui_screen_switch  # 从子菜单返回：清子菜单区 + 渲染 L1
    fi
    menu_result=$(mktemp)
    UI_MENU_QUIT=1 UI_MENU_RESULT_FILE="$menu_result" ui_menu "" "${ACTIVE_CATEGORIES[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) continue ;;   # Esc（主菜单无上级，忽略）
        255) break   ;;   # Q：退出程序
        *)   break   ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    local category="${ACTIVE_CATEGORIES[$choice]}"
    if [[ "$category" == "关于项目" ]]; then
      handle_about_project
      preserve_output=1
    elif [[ "$category" == "一键部署" ]]; then
      handle_solution_sub_menu
    else
      handle_auto_sub_menu "$category"
    fi
  done

  # 当前菜单已保留在屏幕上，退出日志直接追加在菜单下方，避免重复快照
  ui_cursor_show
  log_info "用户退出 DebNAS"
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
  # 界面选择：TTY + UTF-8 时使用方案 A 双栏仪表盘；非 TTY 或 DEBNAS_UI=classic 回退旧版菜单
  local use_dashboard=0
  if ui_dashboard_available; then
    use_dashboard=1
  else
    ui_screen_clear    # 旧版界面：仅此一次清屏（仪表盘使用备用屏幕，不清主屏）
  fi

  setup_environment

  # 系统检查
  if ! verify_system_support 2>/dev/null; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 发现模块并使用自动发现模式
  discover_modules 2>/dev/null
  load_solutions

  if [[ $use_dashboard -eq 1 ]]; then
    if ui_dashboard_main "${_MENU_TMP_DIR:-}"; then
      log_info "用户退出 DebNAS"
      exit 0
    fi
    # 仪表盘初始化失败（如无可用模块）：回退旧版菜单
    ui_screen_clear
  fi
  main_menu_loop
}

main "$@"
