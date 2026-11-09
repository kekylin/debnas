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

# 提示信息样式函数
# 参数：$1 - 文本内容
# 返回值：无
print_prompt() {
  print_colored "COLOR_BLUE" "$1" >&2
}
