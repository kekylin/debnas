#!/bin/bash
# 功能：UI样式库，提供UI相关的样式函数和语义化颜色映射

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/colors.sh（由 bootstrap.sh 加载）

# 语义化颜色映射（用于UI系统）
get_ui_color() {
  local type="$1"
  case "$type" in
    accent)    echo "$COLOR_CYAN" ;;     # 新增：强调色（替代 primary）
    primary)   echo "$COLOR_CYAN" ;;     # 向后兼容旧名
    secondary) echo "$COLOR_WHITE" ;;    # 向后兼容旧名
    dim)       echo "$COLOR_DIM" ;;      # 新增：灰色辅助文字
    success)   echo "$COLOR_GREEN" ;;
    warning)   echo "$COLOR_YELLOW" ;;
    error)     echo "$COLOR_RED" ;;
    info)      echo "$COLOR_BLUE" ;;
    highlight) echo "$COLOR_CYAN" ;;     # 迁移 MAGENTA→CYAN（设计规范 §2.1.3）
    *)         echo "$COLOR_RESET" ;;    # 默认返回 RESET
  esac
}

# 样式函数：带颜色的文本输出
# 参数：$1 - 颜色变量名，$2 - 文本内容
# 返回值：无
print_colored() {
  local color_var="$1"
  local text="$2"
  local color="${!color_var}"
  printf "%s%s%s\n" "$color" "$text" "$COLOR_RESET"
}

# 灰色辅助文字输出（用于 Footer、版本号、面包屑）
print_dim() {
  print_colored "COLOR_DIM" "$1"
}

# 青色强调文字输出（用于选中菜单项、快捷键）
print_accent() {
  print_colored "COLOR_CYAN" "$1"
}

# @deprecated Phase 1: 横幅样式函数（Phase 2 由 ui_header 替代）
# 参数：$1 - 文本内容
# 返回值：无
print_banner_text() {
  print_colored "COLOR_WHITE" "$1"
}

# 标题样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_title() {
  print_colored "COLOR_GREEN" "$1"
}

# 成功信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_success() {
  print_colored "COLOR_GREEN" "$1"
}

# 警告信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_warning() {
  print_colored "COLOR_YELLOW" "$1"
}

# 错误信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_error() {
  print_colored "COLOR_RED" "$1"
}

# 信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_info() {
  print_colored "COLOR_BLUE" "$1"
}

# @deprecated Phase 1: 高亮样式函数（MAGENTA 已禁用，改用 print_accent）
# 参数：$1 - 文本内容
# 返回值：无
print_highlight() {
  print_colored "COLOR_CYAN" "$1"
}

# @deprecated Phase 1: 分隔线样式函数（设计规范：用空行呼吸感替代分隔线）
# 参数：$1 - 分隔线字符（可选，默认=）
# 返回值：无
print_separator() {
  local char="${1:-=}"
  local line
  line=$(printf '%*s' 50 '' | tr ' ' "$char")
  print_colored "COLOR_CYAN" "$line"
}

# @deprecated Phase 1: 菜单项样式函数（Phase 2 由 ui_menu 替代）
# 参数：$1 - 编号，$2 - 文本内容，$3 - 是否为退出选项（可选）
# 返回值：无
print_menu_item() {
  local number="$1"
  local text="$2"
  local is_exit="${3:-false}"
  
  if [[ "$is_exit" == "true" ]]; then
    # 退出选项使用不同颜色
    printf "%s%s.%s%s\n" "$COLOR_YELLOW" "$number" "$text" "$COLOR_RESET"
  else
    # 普通菜单项使用统一格式（点号分隔）
    printf "%s%s.%s%s\n" "$COLOR_WHITE" "$number" "$text" "$COLOR_RESET"
  fi
}

# @deprecated Phase 1: 主菜单项样式函数（Phase 2 由 ui_menu 替代）
# 参数：$1 - 编号，$2 - 文本内容
# 返回值：无
print_main_menu_item() {
  local number="$1"
  local text="$2"
  printf "%s%s.%s%s\n" "$COLOR_WHITE" "$number" "$text" "$COLOR_RESET"
}

# @deprecated Phase 1: 子菜单标题样式函数（Phase 2 由 ui_header + 面包屑替代）
# 参数：$1 - 标题文本
# 返回值：无
print_submenu_title() {
  local title="$1"
  local side_length=20  # 缩减到每边20个字符的分隔线
  
  # 构建分隔线
  local line=""
  for ((i=0; i<side_length; i++)); do
    line+="-"
  done
  
  printf "%s%s %s %s%s\n" "$COLOR_CYAN" "$line" "$title" "$line" "$COLOR_RESET"
}

# 提示信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_prompt() {
  print_colored "COLOR_BLUE" "$1" >&2
}

# 多选提示信息样式函数
# 参数：无
# 返回值：无
print_multiselect_prompt() {
  print_colored "COLOR_GREEN" "${MSG_MULTISELECT:-支持多选，空格分隔多个编号，如：1 2 3}"
} 