#!/bin/bash
# 功能：核心颜色定义库
# 作者：kekylin
# 创建时间：2025-07-13
# 修改时间：2025-07-13
#
# 用法：source colors.sh 后使用基础颜色变量
# 注意：这是最底层的颜色定义，不包含业务逻辑

set -euo pipefail
IFS=$'\n\t'

# 检查是否禁用颜色输出
if [[ "${NO_COLOR:-0}" -eq 1 ]] || [[ ! -t 1 ]]; then
  # 禁用颜色时的空字符串
  COLOR_RESET=""
  # 基础颜色（全部使用普通字体，非粗体）
  COLOR_BLACK=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_MAGENTA=""
  COLOR_CYAN=""
  COLOR_WHITE=""
else
  # 启用颜色时的ANSI转义序列（全部使用普通字体，非粗体）
  COLOR_RESET=$'\e[0m'         # 重置颜色
  # 基础颜色（全部使用普通字体，非粗体）
  COLOR_BLACK=$'\e[0;30m'      # 黑色（普通字体）
  COLOR_RED=$'\e[0;31m'        # 红色（普通字体）
  COLOR_GREEN=$'\e[0;32m'      # 绿色（普通字体）
  COLOR_YELLOW=$'\e[0;33m'     # 黄色（普通字体）
  COLOR_BLUE=$'\e[0;34m'       # 蓝色（普通字体）
  COLOR_MAGENTA=$'\e[0;35m'    # 紫色（普通字体）
  COLOR_CYAN=$'\e[0;36m'       # 青色（普通字体）
  COLOR_WHITE=$'\e[0;37m'      # 白色（普通字体）
fi 