#!/bin/bash
# 功能：通用用户界面工具库 — 菜单交互与输入
# Phase 2: 新增 read_key() 方向键捕获 + ui_menu() 交互菜单（局部刷新）

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh, ui/styles.sh（由 bootstrap.sh 加载）

# ═══════════════════════════════════════════════════════════════
# Phase 2 新增函数 — 方向键导航菜单
# ═══════════════════════════════════════════════════════════════

# 读取单个键盘按键（含方向键、Vim 兼容键）
# 输出（stdout）：UP / DOWN / ENTER / ESC / Q / NUM:n / OTHER:c
# 非终端 stdin → 输出 "ESC" 并返回 1（安全降级）
read_key() {
  # 非终端输入 → 安全退出
  if [[ ! -t 0 ]]; then
    echo "ESC"
    return 1
  fi

  local key
  IFS= read -r -s -n 1 key || { echo "ESC"; return 0; }

  # ESC 序列：尝试读取更多字节（方向键为多字节序列）
  if [[ "$key" == $'\033' ]]; then
    local rest
    IFS= read -r -s -n 2 -t 0.001 rest 2>/dev/null || true
    key+="$rest"
    case "$key" in
      $'\033[A'|$'\033OA') echo "UP";    return 0 ;;  # 上（ANSI + 应用模式）
      $'\033[B'|$'\033OB') echo "DOWN";  return 0 ;;  # 下
      $'\033[C'|$'\033OC') echo "RIGHT"; return 0 ;;  # 右（预留）
      $'\033[D'|$'\033OD') echo "LEFT";  return 0 ;;  # 左（预留）
      $'\033')             echo "ESC";   return 0 ;;  # 纯 ESC
    esac
  elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
    echo "ENTER"; return 0
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    echo "Q"; return 0
  elif [[ "$key" == "j" || "$key" == "J" ]]; then
    echo "DOWN"; return 0    # Vim 风格：j = 下
  elif [[ "$key" == "k" || "$key" == "K" ]]; then
    echo "UP"; return 0      # Vim 风格：k = 上
  elif [[ "$key" =~ ^[1-9]$ ]]; then
    echo "NUM:$key"; return 0
  fi
  echo "OTHER:$key"
}

# ═══════════════════════════════════════════════════════════════
# ui_menu — 交互式菜单（方向键导航 + 局部刷新）
# ═══════════════════════════════════════════════════════════════

# 交互式菜单（方向键导航 + 局部刷新）
# 参数：$1           — 面包屑标题（空串 = 主菜单，不显示面包屑）
#       shift 后剩余  — 菜单项列表
# 环境变量：
#   UI_MENU_QUIT=1          — 启用 Q 退出（仅主菜单设置）
#   UI_MENU_BACK_LABEL      — 返回按钮标签（默认 ""，空则不显示返回按钮）
# 输出（stdout）：选中的索引（0-based）
# 退出码：0=正常选择, 254=返回上级(Esc), 255=退出程序(Q)
ui_menu() {
  local breadcrumb="${1:-}"
  shift
  local -a items=("$@")
  local item_count="${#items[@]}"
  local back_label="${UI_MENU_BACK_LABEL:-}"
  local enable_quit="${UI_MENU_QUIT:-0}"

  # 空菜单：直接返回
  if [[ $item_count -eq 0 ]]; then
    return 254
  fi

  local focus_idx=0       # 当前焦点（items 数组索引）
  local old_focus=-1      # 上一次焦点（用于局部刷新）
  local total_lines=0     # 渲染总行数（面包屑 + 菜单项 + 底部标签）

  # ---- 计算渲染行数 ----
  local breadcrumb_lines=0
  if [[ -n "$breadcrumb" ]]; then
    breadcrumb_lines=2    # 面包屑文字 + 空行
  fi
  local bottom_lines=0
  if [[ -n "$back_label" || "$enable_quit" -eq 1 ]]; then
    bottom_lines=1
  fi
  total_lines=$(( breadcrumb_lines + item_count + bottom_lines ))

  # ---- 行号映射（0-based，从上到下） ----
  # 行 0: 面包屑 (如有)
  # 行 1: 空行 (如有)
  # 行 breadcrumb_lines .. breadcrumb_lines+item_count-1: 菜单项
  # 行 total_lines-1: 底部标签 (如有)

  # ---- 计算项索引对应的渲染行号 ----
  _item_to_line() {
    local idx=$1
    echo $(( breadcrumb_lines + idx ))
  }

  # ---- 全量渲染 Content 区域 ----
  _ui_menu_render_all() {
    local i line
    # 面包屑
    if [[ -n "$breadcrumb" ]]; then
      printf '  %b%s%b\n' "$COLOR_DIM" "$breadcrumb" "$COLOR_RESET"
      printf '\n'
    fi

    # 菜单项
    for i in "${!items[@]}"; do
      if [[ $i -eq $focus_idx ]]; then
        printf ' %b>%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "${items[$i]}"
      else
        printf '   %s\n' "${items[$i]}"
      fi
    done

    # 底部标签（快捷键提示）
    if [[ -n "$back_label" ]]; then
      printf '  %b%s%b\n' "$COLOR_DIM" "$back_label" "$COLOR_RESET"
    elif [[ "$enable_quit" -eq 1 ]]; then
      printf '  %bQ 退出%b\n' "$COLOR_DIM" "$COLOR_RESET"
    fi
  }

  # ---- 局部刷新：重绘单行 ----
  # $1 = 渲染行号 (0-based), $2 = 行类型 (item/breadcrumb/bottom), $3 = 项索引 (仅 item 类型)
  _ui_menu_draw_line() {
    local line=$1 type=$2 idx=$3

    # 定位到目标行
    local up_count=$(( total_lines - line ))
    printf '\033[%dA' "$up_count"
    printf '\r\033[K'  # 回车 + 清除行

    case "$type" in
      breadcrumb)
        printf '  %b%s%b\n' "$COLOR_DIM" "$breadcrumb" "$COLOR_RESET"
        ;;
      bottom)
        if [[ -n "$back_label" ]]; then
          printf '  %b%s%b\n' "$COLOR_DIM" "$back_label" "$COLOR_RESET"
        elif [[ "$enable_quit" -eq 1 ]]; then
          printf '  %bQ 退出%b\n' "$COLOR_DIM" "$COLOR_RESET"
        fi
        ;;
      item)
        if [[ $idx -eq $focus_idx ]]; then
          printf ' %b>%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "${items[$idx]}"
        else
          printf '   %s\n' "${items[$idx]}"
        fi
        ;;
    esac
  }

  # ---- 局部刷新：焦点移动（仅重写旧行和新行） ----
  _ui_menu_move_focus() {
    local old_idx=$1 new_idx=$2
    local old_item_line new_item_line

    old_item_line=$(_item_to_line "$old_idx")
    new_item_line=$(_item_to_line "$new_idx")

    # 恢复光标到保存位置（Content 末尾）
    printf '\033[u'

    # 重写旧焦点行（移除 ">" 指示器）
    _ui_menu_draw_line "$old_item_line" "item" "$old_idx"

    # 恢复光标
    printf '\033[u'

    # 重写新焦点行（添加 ">" 指示器）
    _ui_menu_draw_line "$new_item_line" "item" "$new_idx"

    # 恢复光标（保持在 Content 末尾）
    printf '\033[u'
  }

  # ═══════════════ 首次渲染 ═══════════════
  _ui_menu_render_all

  # 保存 Content 末尾位置（所有局部刷新从这儿开始向上定位）
  printf '\033[s'

  # ═══════════════ 主循环 ═══════════════
  while true; do
    local key
    key=$(read_key) || { return 254; }  # 非终端 → 安全退出

    case "$key" in
      UP)
        if [[ $focus_idx -gt 0 ]]; then
          old_focus=$focus_idx
          ((focus_idx--)) || true
          _ui_menu_move_focus "$old_focus" "$focus_idx"
        fi
        ;;
      DOWN)
        if [[ $focus_idx -lt $((item_count - 1)) ]]; then
          old_focus=$focus_idx
          ((focus_idx++)) || true
          _ui_menu_move_focus "$old_focus" "$focus_idx"
        fi
        ;;
      ENTER)
        echo "$focus_idx"
        return 0
        ;;
      ESC)
        if [[ -n "$back_label" ]]; then
          return 254
        fi
        # 无返回按钮（主菜单）：忽略 ESC
        ;;
      Q)
        if [[ "$enable_quit" -eq 1 ]]; then
          return 255
        elif [[ -n "$back_label" ]]; then
          return 254  # 子菜单中 Q 等同于返回
        fi
        ;;
      NUM:*)
        # 数字快速跳转（1-9 → 索引 0-8）
        local num="${key#NUM:}"
        local idx=$(( num - 1 ))
        if [[ $idx -ge 0 && $idx -lt $item_count ]]; then
          old_focus=$focus_idx
          focus_idx=$idx
          _ui_menu_move_focus "$old_focus" "$focus_idx"
        fi
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# 以下为旧版函数（保留向后兼容，Phase 3 逐步迁移）
# ═══════════════════════════════════════════════════════════════

# @deprecated Phase 2: 显示菜单选项（由 ui_menu 替代）
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
    ((idx++)) || true
  done
  print_menu_item "0" "${MSG_BACK:-返回}" "true"
}

# @deprecated Phase 2: 显示带分隔线的菜单（由 ui_menu 替代）
# 参数：$1 - 菜单标题，$2... - 菜单选项数组
# 返回值：无
show_menu_with_border() {
  local title="$1"
  shift
  local -a options=("$@")
  
  print_submenu_title "$title"
  show_menu "" "${options[@]}"
}

# @deprecated Phase 2: 获取用户选择（由 ui_menu 替代）
# 参数：$1 - 最大选项数
# 返回值：用户选择的编号（0表示返回）
get_user_choice() {
  local max_options="$1"
  local choice

  print_prompt "请选择编号: "
  read -r choice || {
    # EOF / CTRL-D：视为用户选择退出
    echo ""
    echo "0"
    return 0
  }

  # 清理空白字符（对齐 threat-ips 行为）
  choice=$(printf "%s" "${choice}" | tr -d '[:space:]')

  if [[ -z "$choice" ]]; then
    log_error "${MSG_INVALID_INPUT:-请输入数字编号}"
    return 1
  fi

  # 验证输入
  if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
    log_error "${MSG_INVALID_INPUT:-请输入数字编号}"
    return 1
  fi

  if [[ "$choice" -lt 0 ]] || [[ "$choice" -gt "$max_options" ]]; then
    log_error "${MSG_INVALID_CHOICE:-无效选择}，请输入 0-$max_options"
    return 1
  fi

  echo "$choice"
  return 0
}

# @deprecated Phase 2: 运行交互式子菜单循环（由 ui_menu 替代）
# 参数：$1 - 菜单标题，后续参数为 "函数名" "显示标签" 交替对
# 返回值：0（用户选择 0 返回时）
# 说明：被调度的函数应 return（而非 exit），以保持菜单循环继续
run_submenu() {
  local title="$1"
  shift

  local -a labels=()
  local -a funcs=()
  while [[ $# -gt 0 ]]; do
    funcs+=("$1")
    labels+=("$2")
    shift 2
  done

  local max="${#labels[@]}"

  while true; do
    print_separator "-"
    local idx=1
    for label in "${labels[@]}"; do
      print_menu_item "$idx" "$label"
      ((idx++)) || true
    done
    print_menu_item "0" "${MSG_BACK:-返回}" "true"
    print_separator "-"

    local choice
    choice=$(get_user_choice "$max") || continue

    if [[ "$choice" -eq 0 ]]; then
      return 0
    fi

    "${funcs[$((choice-1))]}"
  done
}

 