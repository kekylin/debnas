#!/bin/bash
# 功能：交互菜单系统
# 说明：使用 discover_modules() 自动发现模块并生成菜单
# 兼容：保留与 bin/main.sh 一致的交互体验

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 常量定义 ====================

# 分类显示顺序
declare -a MENU_CATEGORY_ORDER=(
  "基础系统"
  "管理面板"
  "安全防护"
  "容器管理"
  "通知服务"
  "系统工具"
  "一键部署"
)


# ==================== 自动发现模式菜单 ====================

# 构建当前有效分类列表（只包含有模块的分类）
declare -a ACTIVE_CATEGORIES=()

build_active_categories() {
  ACTIVE_CATEGORIES=()
  for category in "${MENU_CATEGORY_ORDER[@]}"; do
    local -a modules
    mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
    if [[ ${#modules[@]} -gt 0 ]]; then
      ACTIVE_CATEGORIES+=("$category")
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

  print_menu_item "0" "退出" "true"
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
    ((idx++))
  done
  print_menu_item "0" "返回" "true"
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
    local mod_path
    mod_path=$(get_module_path "$module_name" 2>/dev/null) || {
      log_fail "模块 \"$display_name\" 路径不存在，已跳过"
      continue
    }

    log_action "正在执行模块：\"$display_name\""
    if ! (unset _DEBNAS_BOOTSTRAPPED; bash "$mod_path"); then
      log_fail "模块 \"$display_name\" 执行失败，已中断"
      break
    fi
    log_success "模块 \"$display_name\" 执行完成"
  done
}

# 自动发现模式子菜单处理
handle_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  while true; do
    show_auto_sub_menu "$category"
    print_prompt "请选择编号: "
    read -r sub_choices

    [[ -z "$sub_choices" ]] && {
      log_fail "输入为空，请重新输入"
      continue
    }

    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"

    # 验证输入
    local valid=true
    for choice in "${choices_array[@]}"; do
      if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_fail "仅支持数字编号"
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
      log_fail "无效选择，请重新输入"
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
    print_prompt "请选择编号: "
    read -r main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
      log_fail "请输入数字编号"
      continue
    fi

    if [[ "$main_choice" == "0" ]]; then
      log_action "用户选择退出"
      exit 0
    fi

    if [[ "$main_choice" -lt 1 || "$main_choice" -gt "${#ACTIVE_CATEGORIES[@]}" ]]; then
      log_fail "无效选择"
      continue
    fi

    local category="${ACTIVE_CATEGORIES[$((main_choice-1))]}"
    handle_auto_sub_menu "$category"
  done
}

# ==================== 环境设置 ====================

# 设置临时目录和信号处理
setup_environment() {
  init_temp_dir
  _MENU_TMP_DIR=$(mktemp -d "${DEBNAS_TMP_BASE}/menu.XXXXXX")
  chmod 755 "$_MENU_TMP_DIR"
  trap 'log_warning "用户中断操作"; rm -rf "$_MENU_TMP_DIR"; exit 1' INT
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
  auto_menu_loop
}

main "$@"
