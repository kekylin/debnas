#!/bin/bash
# 功能：交互菜单系统
# 说明：使用 discover_modules() 自动发现模块并生成菜单
# 交互菜单入口

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 常量定义 ====================

# 分类显示顺序（使用 i18n 变量，支持多语言）
declare -a MENU_CATEGORY_ORDER=(
  "${MSG_CAT_BASIC}"
  "${MSG_CAT_PANEL}"
  "${MSG_CAT_SECURITY}"
  "${MSG_CAT_CONTAINER}"
  "${MSG_CAT_NOTIFY}"
  "${MSG_CAT_TOOLS}"
  "${MSG_CAT_DEPLOY}"
)

# ==================== 横幅显示 ====================

print_banner() {
  print_separator "="
  print_banner_text "                     DebNAS"
  print_banner_text "                                  QQ群：339169752"
  print_banner_text "作者：kekylin"
  print_banner_text "项目：https://github.com/kekylin/debnas"
  print_separator "-"
  print_title "温馨提示"
  print_title "·一键部署适合自动配置环境，也可按选择单项功能"
  print_title "·安装防火墙后需重启系统以确保服务正常"
  print_separator "="
}

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

# 部署方案子菜单
show_solution_sub_menu() {
  print_submenu_title "${MSG_CAT_DEPLOY}"
  local i
  for i in "${!SOLUTION_NAMES[@]}"; do
    print_menu_item "$((i+1))" "${SOLUTION_DISPLAY_NAMES[$i]}"
  done
  print_menu_item "0" "${MSG_BACK}" "true"
  print_separator "-"
}

handle_solution_sub_menu() {
  while true; do
    show_solution_sub_menu
    print_prompt "${MSG_SELECT}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
      log_fail "${MSG_INVALID_INPUT}"
      continue
    fi

    if [[ "$choice" == "0" ]]; then
      break
    fi

    if [[ "$choice" -lt 1 || "$choice" -gt "${#SOLUTION_NAMES[@]}" ]]; then
      log_fail "${MSG_INVALID_CHOICE}"
      continue
    fi

    execute_solution "${SOLUTION_NAMES[$((choice-1))]}"
    break
  done
}

# ==================== 自动发现模式菜单 ====================

# 构建当前有效分类列表
declare -a ACTIVE_CATEGORIES=()

build_active_categories() {
  ACTIVE_CATEGORIES=()
  for category in "${MENU_CATEGORY_ORDER[@]}"; do
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

# 显示自动发现模式的主菜单
show_auto_main_menu() {
  print_banner

  local i
  for i in "${!ACTIVE_CATEGORIES[@]}"; do
    print_main_menu_item "$((i+1))" "${ACTIVE_CATEGORIES[$i]}"
  done

  print_menu_item "0" "${MSG_EXIT}" "true"
  print_separator "="
}

# 显示自动发现模式的子菜单
show_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  print_submenu_title "$category"
  local idx=1
  for module_name in "${modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    print_menu_item "$idx" "$display_name"
    ((idx++)) || true
  done
  print_menu_item "0" "${MSG_BACK}" "true"
  print_separator "-"
  print_multiselect_prompt
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

# 自动发现模式子菜单处理
handle_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  while true; do
    show_auto_sub_menu "$category"
    print_prompt "${MSG_SELECT}"
    read -r sub_choices

    [[ -z "$sub_choices" ]] && {
      log_fail "${MSG_INVALID_INPUT}"
      continue
    }

    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"

    # 验证输入
    local valid=true
    for choice in "${choices_array[@]}"; do
      if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_fail "${MSG_INVALID_INPUT}"
        valid=false
        break
      fi
    done
    [[ "$valid" == "false" ]] && continue

    # 处理返回
    [[ " $sub_choices " =~ " 0 " ]] && break

    # 收集选择
    local -a selected=()
    for choice in "${choices_array[@]}"; do
      if [[ "$choice" -ge 1 && "$choice" -le "${#modules[@]}" ]]; then
        selected+=("${modules[$((choice-1))]}")
      fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
      log_fail "${MSG_INVALID_CHOICE}"
      continue
    fi

    execute_auto_modules "$category" "${selected[@]}"
    break
  done
}

# 自动发现模式主循环
auto_menu_loop() {
  build_active_categories

  while true; do
    show_auto_main_menu
    print_prompt "${MSG_SELECT}"
    read -r main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
      log_fail "${MSG_INVALID_INPUT}"
      continue
    fi

    if [[ "$main_choice" == "0" ]]; then
      log_action "exit"
      exit 0
    fi

    if [[ "$main_choice" -lt 1 || "$main_choice" -gt "${#ACTIVE_CATEGORIES[@]}" ]]; then
      log_fail "${MSG_INVALID_CHOICE}"
      continue
    fi

    local category="${ACTIVE_CATEGORIES[$((main_choice-1))]}"
    if [[ "$category" == "${MSG_CAT_DEPLOY}" ]]; then
      handle_solution_sub_menu
    else
      handle_auto_sub_menu "$category"
    fi
  done
}

# ==================== 环境设置 ====================

# 设置临时目录和信号处理
setup_environment() {
  init_temp_dir
  _MENU_TMP_DIR=$(mktemp -d "${DEBNAS_TMP_BASE}/menu.XXXXXX")
  chmod 700 "$_MENU_TMP_DIR"
  trap 'if [[ ! -f /tmp/.debnas_signal_handled ]]; then touch /tmp/.debnas_signal_handled 2>/dev/null; log_warning "用户中断操作"; fi; rm -rf "$_MENU_TMP_DIR"; exit 1' INT
  trap 'rm -rf "$_MENU_TMP_DIR"' EXIT
}

# ==================== 主入口 ====================

main() {
  clear 2>/dev/null || true
  setup_environment

  # 系统检查
  if ! verify_system_support 2>/dev/null; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 发现模块并使用自动发现模式
  discover_modules 2>/dev/null
  load_solutions
  auto_menu_loop
}

main "$@"
