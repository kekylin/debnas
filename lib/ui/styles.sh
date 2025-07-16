#!/bin/bash
# 功能：UI样式库，提供UI相关的样式函数和语义化颜色映射
# 作者：kekylin
# 创建时间：2025-07-13
# 修改时间：2025-07-13
#
# 用法：source styles.sh 后使用UI样式函数
# 注意：依赖 lib/core/colors.sh

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载核心颜色定义
source "$LIB_DIR/core/colors.sh"

# 语义化颜色映射（用于UI系统）
get_ui_color() {
  local type="$1"
  case "$type" in
    primary)   echo "$COLOR_CYAN" ;;
    secondary) echo "$COLOR_WHITE" ;;
    success)   echo "$COLOR_GREEN" ;;
    warning)   echo "$COLOR_YELLOW" ;;
    error)     echo "$COLOR_RED" ;;
    info)      echo "$COLOR_BLUE" ;;
    highlight) echo "$COLOR_MAGENTA" ;;
    *)         echo "$COLOR_WHITE" ;;
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

# 横幅样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_banner_text() {
  print_colored "COLOR_WHITE" "$1"
}

# 标题样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_title() {
  print_colored "COLOR_CYAN" "$1"
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

# 高亮样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_highlight() {
  print_colored "COLOR_MAGENTA" "$1"
}

# 分隔线样式函数
# 参数：$1 - 分隔线字符（可选，默认=）
# 返回值：无
print_separator() {
  local char="${1:-=}"
  local line=""
  for ((i=0; i<50; i++)); do
    line+="$char"
  done
  print_colored "COLOR_CYAN" "$line"
}

# 菜单项样式函数
# 参数：$1 - 编号，$2 - 文本内容
# 返回值：无
print_menu_item() {
  local number="$1"
  local text="$2"
  # 使用统一颜色，提高视觉一致性
  printf "%s%s、%s%s\n" "$COLOR_WHITE" "$number" "$text" "$COLOR_RESET"
}

# 提示信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_prompt() {
  print_colored "COLOR_BLUE" "$1"
} 