#!/bin/bash
# 功能：通用用户界面工具库

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"
source "$LIB_DIR/ui/styles.sh"

# 显示菜单选项
# 参数：$1 - 菜单标题（可选），$2... - 菜单选项数组
# 返回值：无
show_menu() {
  local title="${1:-}"
  shift
  local -a options=("$@")
  
  # 显示标题
  if [[ -n "$title" ]]; then
    print_title "$title"
  fi
  
  # 显示菜单选项
  local idx=1
  for option in "${options[@]}"; do
    print_menu_item "${idx}" "${option}"
    ((idx++))
  done
  print_menu_item "0" "返回" "true"
}

# 显示带分隔线的菜单
# 参数：$1 - 菜单标题，$2... - 菜单选项数组
# 返回值：无
show_menu_with_border() {
  local title="$1"
  shift
  local -a options=("$@")
  
  print_submenu_title "$title"
  show_menu "" "${options[@]}"
}

# 获取用户选择
# 参数：$1 - 最大选项数
# 返回值：用户选择的编号（0表示返回）
get_user_choice() {
  local max_options="$1"
  local choice
  
  print_prompt "请选择编号: "
  read -r choice
  
  # 验证输入
  if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
    log_error "请输入数字编号"
    return 1
  fi
  
  if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt "$max_options" ]]; then
    log_error "无效选择，请输入 0-$max_options"
    return 1
  fi
  
  echo "$choice"
  return 0
}

# 获取用户多选
# 参数：$1 - 最大选项数
# 返回值：用户选择的编号数组
get_user_multiple_choice() {
  local max_options="$1"
  local choices
  
  print_multiselect_prompt
  print_prompt "请选择编号: "
  read -r choices
  
  # 验证输入
  if [[ -z "$choices" ]]; then
    log_error "输入为空，请重新输入"
    return 1
  fi
  
  # 分割输入并验证
  local -a choices_array
  IFS=' ' read -ra choices_array <<< "$choices"
  
  for choice in "${choices_array[@]}"; do
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
      log_error "仅支持数字编号"
      return 1
    fi
    
    if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt "$max_options" ]]; then
      log_error "无效选择，请输入 0-$max_options"
      return 1
    fi
  done
  
  printf '%s\n' "${choices_array[@]}"
  return 0
}

# 显示确认对话框
# 参数：$1 - 确认消息
# 返回值：0确认，1取消
show_confirm() {
  local message="$1"
  local choice
  
  read -rp "$message (y/N): " choice
  if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
    return 0
  else
    return 1
  fi
}

# 显示带说明的菜单
# 参数：$1 - 菜单标题，$2 - 说明文字，$3... - 菜单选项数组
# 返回值：无
show_menu_with_description() {
  local title="$1"
  local description="$2"
  shift 2
  local -a options=("$@")
  
  print_title "---------------- $title ----------------"
  if [[ -n "$description" ]]; then
    print_info "$description"
    echo ""
  fi
  show_menu "" "${options[@]}"
} 