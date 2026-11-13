#!/bin/bash
# 功能：Footer 组件 — 模式 A 固定底栏（内容栏为终端宽度的一半）
# 说明：在居中内容栏内渲染底部快捷键提示（左侧）+ 版本号（右侧）
# 依赖：core/colors.sh（COLOR_DIM、COLOR_RESET）、layout.sh（_UI_CONTENT_WIDTH/_UI_LEFT_MARGIN）

set -euo pipefail
IFS=$'\n\t'

# 渲染 Footer（内容栏内左侧快捷键 + 右侧版本号；放不下时截断快捷键）
# 参数：$1 — 快捷键提示字符串（如 "↑↓ 选择  Enter 确认  Q 退出"）
# 全局依赖：$COLUMNS, $DEBNAS_VERSION, $_UI_CONTENT_WIDTH, $_UI_LEFT_MARGIN
# 输出：stdout
ui_footer() {
  local shortcuts="${1:-}"
  local version="${DEBNAS_VERSION:-未知}"
  local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
  local width="${_UI_CONTENT_WIDTH:-$(( cols / 2 ))}"
  local left="${_UI_LEFT_MARGIN:-0}"
  local margin=$(( left + ${_UI_BREAD_INDENT:-5} ))
  local inner=$(( width - ${_UI_BREAD_INDENT:-5} ))
  (( inner < 1 )) && inner=1

  # 有新版本时在版本号前显示绿色圆点（由菜单在一级页面置位 _UI_FOOTER_UPDATE_DOT=1）
  local dot="" dot_bare="" dot_w=0
  if [[ "${_UI_FOOTER_UPDATE_DOT:-0}" -eq 1 ]]; then
    dot="${COLOR_GREEN}● ${COLOR_DIM}"       # 点后用 COLOR_DIM 续接版本号
    dot_bare="${COLOR_GREEN}●${COLOR_RESET}"
    dot_w=2
  fi

  _ui_fit_text "$shortcuts" 9999
  local shortcut_w=$_UI_FIT_WIDTH
  if (( shortcut_w + dot_w + ${#version} + 2 <= inner )); then
    local padding=$(( inner - shortcut_w - dot_w - ${#version} - 2 ))
    (( padding < 2 )) && padding=2
    # 间距用独立的 %*s 打印：%*s 的宽度小于版本号长度时不补空格，直接写 "%*s"(version)
    # 会让快捷键和版本号贴在一起（"Q 退出v2026.11.1"）
    printf "%b%*s%s%*s%b%b\n" "$COLOR_DIM" "$margin" '' "$shortcuts" "$padding" '' "$dot$version" "$COLOR_RESET"
  else
    # 内容栏放不下“快捷键 + 版本号”：优先保留完整快捷键，再考虑只保留绿点
    _ui_fit_text "$shortcuts" "$inner"; shortcuts="$_UI_FIT_TEXT"
    if (( dot_w > 0 && _UI_FIT_WIDTH + 2 <= inner )); then
      local padding=$(( inner - _UI_FIT_WIDTH - 1 ))
      (( padding < 1 )) && padding=1
      printf "%b%*s%s%*s%b%b\n" "$COLOR_DIM" "$margin" '' "$shortcuts" "$padding" '' "$dot_bare" "$COLOR_RESET"
      return 0
    fi
    printf "%b%*s%s%b\n" "$COLOR_DIM" "$margin" '' "$shortcuts" "$COLOR_RESET"
  fi
}
