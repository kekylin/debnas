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
# 输出（stdout）：UP / DOWN / ENTER / ESC / Q / REDRAW / NUM:n / OTHER:c
# 非终端 stdin → 输出 "ESC" 并返回 1（安全降级）
# Phase 4: SIGWINCH 感知 — 检测 _UI_NEEDS_REDRAW 标志，返回 "REDRAW"
# 最后一次 read_key() 结果（供调用方读取，替代命令替换以规避子 shell 问题）
_READ_KEY_RESULT=""

read_key() {
  # 非终端输入 → 安全退出
  if [[ ! -t 0 ]]; then
    _READ_KEY_RESULT="ESC"
    return 1
  fi

  # Phase 4: 检查是否有待处理的 SIGWINCH 重绘
  if [[ "${_UI_NEEDS_REDRAW:-0}" -eq 1 ]]; then
    _READ_KEY_RESULT="REDRAW"
    return 0
  fi

  local key
  IFS= read -r -s -n 1 key || {
    # read 可能被 SIGWINCH 中断
    if [[ "${_UI_NEEDS_REDRAW:-0}" -eq 1 ]]; then
      _READ_KEY_RESULT="REDRAW"
      return 0
    fi
    _READ_KEY_RESULT="ESC"; return 0
  }

  # 空 key：用户直接按 Enter（未输入任何字符），read -n 1 遇到分隔符 \n 立即返回
  # Bash 行为：读到分隔符之前没有普通字符 → key 为空串，退出码为 0
  if [[ -z "$key" ]]; then
    _READ_KEY_RESULT="ENTER"; return 0
  fi

  # ESC 序列：尝试读取更多字节（方向键为多字节序列）
  if [[ "$key" == $'\033' ]]; then
    local rest
    # 10ms 超时 + 最多读 10 字节：防止快按时 B 字节未到达导致序列撕裂
    IFS= read -r -s -n 10 -t 0.01 rest 2>/dev/null || true
    key+="$rest"
    case "$key" in
      $'\033[A'|$'\033OA') _READ_KEY_RESULT="UP";    return 0 ;;  # 上（ANSI + 应用模式）
      $'\033[B'|$'\033OB') _READ_KEY_RESULT="DOWN";  return 0 ;;  # 下
      $'\033[C'|$'\033OC') _READ_KEY_RESULT="RIGHT"; return 0 ;;  # 右（预留）
      $'\033[D'|$'\033OD') _READ_KEY_RESULT="LEFT";  return 0 ;;  # 左（预留）
      $'\033')             _READ_KEY_RESULT="ESC";   return 0 ;;  # 纯 ESC
      *)                   _READ_KEY_RESULT="ESC";   return 0 ;;  # 撕裂序列 → 视为 ESC，不输出乱码
    esac
  elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
    _READ_KEY_RESULT="ENTER"; return 0
  elif [[ "$key" == "q" || "$key" == "Q" ]]; then
    _READ_KEY_RESULT="Q"; return 0
  elif [[ "$key" == "j" || "$key" == "J" ]]; then
    _READ_KEY_RESULT="DOWN"; return 0    # Vim 风格：j = 下
  elif [[ "$key" == "k" || "$key" == "K" ]]; then
    _READ_KEY_RESULT="UP"; return 0      # Vim 风格：k = 上
  elif [[ "$key" =~ ^[1-9]$ ]]; then
    _READ_KEY_RESULT="NUM:$key"; return 0
  fi
  # 无效按键：静默忽略（设计规范 §5.4 — 无效按键静默原则）
  _READ_KEY_RESULT=""
  return 0
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

  # 导出菜单快照静态数据（供 _ui_print_menu_snapshot() 使用）
  _UI_MENU_SNAPSHOT_ITEMS=("${items[@]}")
  _UI_MENU_SNAPSHOT_BREADCRUMB="$breadcrumb"

  # 空菜单：直接返回
  if [[ $item_count -eq 0 ]]; then
    return 254
  fi

  local focus_idx=0       # 当前焦点（items 数组索引）
  local old_focus=-1      # 上一次焦点（用于局部刷新）
  local total_lines=0     # 渲染总行数（面包屑 + 菜单项/指示器 + 底部标签）

  # ---- 计算渲染行数 ----
  # Phase 4: 紧凑模式下面包屑后无空行（breadcrumb_lines 由 2 降为 1）
  local breadcrumb_lines=0
  if [[ -n "$breadcrumb" ]]; then
    if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
      breadcrumb_lines=1  # 仅面包屑文字，无空行
    else
      breadcrumb_lines=2  # 面包屑文字 + 空行
    fi
  fi
  local bottom_lines=0
  if [[ -n "$back_label" || "$enable_quit" -eq 1 ]]; then
    bottom_lines=1
  fi

  # ---- 长菜单滚动状态（§4.2.3） ----
  local header_height=4   # 正常模式：1 空行 + DebNAS + 2 空行
  if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
    header_height=3       # 紧凑模式：1 空行 + DebNAS + 1 空行
  fi
  local footer_height=1
  local _ui_scroll_offset=0   # 首个可见项索引
  local _ui_max_visible=0     # 可见窗口可容纳的最大项数
  local _ui_needs_scroll=0    # 是否需要滚动
  local _ui_top_ind=0         # 顶部指示器行数（0/1）
  local _ui_bot_ind=0         # 底部指示器行数（0/1）
  local _ui_visible_slots=0   # 实际可见项数（扣除指示器后）

  # 计算可见窗口与滚动参数
  _ui_menu_calc_visible() {
    _ui_max_visible=$(( LINES - header_height - breadcrumb_lines - bottom_lines - footer_height ))
    [[ $_ui_max_visible -lt 1 ]] && _ui_max_visible=1
    if [[ $item_count -gt $_ui_max_visible ]]; then
      _ui_needs_scroll=1
    else
      _ui_needs_scroll=0
      _ui_scroll_offset=0
      _ui_top_ind=0; _ui_bot_ind=0
      _ui_visible_slots=$item_count
      return
    fi

    # 计算指示器与可见槽位
    _ui_top_ind=0; _ui_bot_ind=0
    [[ $_ui_scroll_offset -gt 0 ]] && _ui_top_ind=1
    _ui_visible_slots=$(( _ui_max_visible - _ui_top_ind ))
    if [[ $(( _ui_scroll_offset + _ui_visible_slots )) -lt $item_count ]]; then
      _ui_bot_ind=1
      _ui_visible_slots=$(( _ui_max_visible - _ui_top_ind - _ui_bot_ind ))
    fi
    [[ $_ui_visible_slots -lt 1 ]] && _ui_visible_slots=1
  }

  # 确保焦点在可见窗口内（必要时调整 scroll_offset）
  _ui_menu_clamp_scroll() {
    [[ $_ui_needs_scroll -eq 0 ]] && return
    # 焦点在可见窗口上方 → 向上滚动
    if [[ $focus_idx -lt $_ui_scroll_offset ]]; then
      _ui_scroll_offset=$focus_idx
    fi
    # 焦点在可见窗口下方 → 向下滚动
    if [[ $focus_idx -ge $(( _ui_scroll_offset + _ui_visible_slots )) ]]; then
      _ui_scroll_offset=$(( focus_idx - _ui_visible_slots + 1 ))
    fi
    # 边界钳位
    [[ $_ui_scroll_offset -lt 0 ]] && _ui_scroll_offset=0
    local max_offset=$(( item_count - _ui_visible_slots ))
    [[ $max_offset -lt 0 ]] && max_offset=0
    [[ $_ui_scroll_offset -gt $max_offset ]] && _ui_scroll_offset=$max_offset
    # 重新计算指示器
    _ui_top_ind=0; _ui_bot_ind=0
    [[ $_ui_scroll_offset -gt 0 ]] && _ui_top_ind=1
    [[ $(( _ui_scroll_offset + _ui_visible_slots )) -lt $item_count ]] && _ui_bot_ind=1
  }

  # 判断项索引是否在可见窗口内
  _ui_menu_item_visible() {
    local idx=$1
    if [[ $_ui_needs_scroll -eq 0 ]]; then
      return 0
    fi
    [[ $idx -ge $_ui_scroll_offset && $idx -lt $(( _ui_scroll_offset + _ui_visible_slots )) ]]
  }

  # ---- 行号映射（0-based，Content 区域内） ----
  # 0: 面包屑, 1: (空行), breadcrumb_lines+...: 菜单项/指示器, total_lines-1: 底部标签
  _item_to_line() {
    local idx=$1
    if [[ $_ui_needs_scroll -eq 0 ]]; then
      echo $(( breadcrumb_lines + idx ))
    else
      echo $(( breadcrumb_lines + _ui_top_ind + idx - _ui_scroll_offset ))
    fi
  }

  # ---- 全量渲染 Content 区域 ----
  _ui_menu_render_all() {
    local i vis_i
    # 面包屑
    if [[ -n "$breadcrumb" ]]; then
      printf '%*s%b%s%b\n' "$_UI_BREAD_INDENT" '' "$COLOR_DIM" "$breadcrumb" "$COLOR_RESET"
      if [[ "${_UI_COMPACT_MODE:-0}" -eq 0 ]]; then
        printf '\n'
      fi
    fi

    if [[ $_ui_needs_scroll -eq 0 ]]; then
      # 无滚动：渲染全部项
      if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
        for i in "${!items[@]}"; do
          if [[ $i -eq $focus_idx ]]; then
            printf '%*s%b%d. %s%b\n' "$_UI_COMPACT_INDENT" '' "$COLOR_CYAN" "$((i + 1))" "${items[$i]}" "$COLOR_RESET"
          else
            printf '%*s%d. %s\n' "$_UI_COMPACT_INDENT" '' "$((i + 1))" "${items[$i]}"
          fi
        done
      else
        for i in "${!items[@]}"; do
          if [[ $i -eq $focus_idx ]]; then
            printf '%*s%b> %s%b\n' "$_UI_BREAD_INDENT" '' "$COLOR_CYAN" "${items[$i]}" "$COLOR_RESET"
          else
            printf '%*s%s\n' "$_UI_ITEM_INDENT" '' "${items[$i]}"
          fi
        done
      fi
    else
      # 滚动模式：只渲染可见项 + 指示器
      if [[ $_ui_top_ind -eq 1 ]]; then
        printf '%*s%b↑ 更多...%b\n' "$_UI_ITEM_INDENT" '' "$COLOR_DIM" "$COLOR_RESET"
      fi
      vis_i=0
      if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
        for (( i = _ui_scroll_offset; i < _ui_scroll_offset + _ui_visible_slots; i++ )); do
          if [[ $i -eq $focus_idx ]]; then
            printf '%*s%b%d. %s%b\n' "$_UI_COMPACT_INDENT" '' "$COLOR_CYAN" "$((i + 1))" "${items[$i]}" "$COLOR_RESET"
          else
            printf '%*s%d. %s\n' "$_UI_COMPACT_INDENT" '' "$((i + 1))" "${items[$i]}"
          fi
          ((vis_i++)) || true
        done
      else
        for (( i = _ui_scroll_offset; i < _ui_scroll_offset + _ui_visible_slots; i++ )); do
          if [[ $i -eq $focus_idx ]]; then
            printf '%*s%b> %s%b\n' "$_UI_BREAD_INDENT" '' "$COLOR_CYAN" "${items[$i]}" "$COLOR_RESET"
          else
            printf '%*s%s\n' "$_UI_ITEM_INDENT" '' "${items[$i]}"
          fi
          ((vis_i++)) || true
        done
      fi
      if [[ $_ui_bot_ind -eq 1 ]]; then
        printf '%*s%b↓ 更多...%b\n' "$_UI_ITEM_INDENT" '' "$COLOR_DIM" "$COLOR_RESET"
      fi
    fi

    # 底部标签
    if [[ -n "$back_label" ]]; then
      ui_footer "↑↓ 选择  Enter 确认  Esc 返回"
    elif [[ "$enable_quit" -eq 1 ]]; then
      ui_footer "↑↓ 选择  Enter 确认  Q 退出"
    fi
  }

  # ---- 局部刷新：重绘单行 ----
  # $1 = 渲染行号 (0-based), $2 = 行类型 (item/breadcrumb/bottom/scroll_indicator)
  # $3 = 项索引 (仅 item 类型，scroll_indicator 时传递 "top" 或 "bottom")
  _ui_menu_draw_line() {
    local line=$1 type=$2 idx=$3

    local up_count=$(( total_lines - line ))
    printf '\033[%dA' "$up_count"
    printf '\r\033[K'

    case "$type" in
      breadcrumb)
        printf '%*s%b%s%b\n' "$_UI_BREAD_INDENT" '' "$COLOR_DIM" "$breadcrumb" "$COLOR_RESET"
        ;;
      bottom)
        if [[ -n "$back_label" ]]; then
          ui_footer "↑↓ 选择  Enter 确认  Esc 返回"
        elif [[ "$enable_quit" -eq 1 ]]; then
          ui_footer "↑↓ 选择  Enter 确认  Q 退出"
        fi
        ;;
      scroll_indicator)
        if [[ "$idx" == "top" ]]; then
          printf '%*s%b↑ 更多...%b\n' "$_UI_ITEM_INDENT" '' "$COLOR_DIM" "$COLOR_RESET"
        else
          printf '%*s%b↓ 更多...%b\n' "$_UI_ITEM_INDENT" '' "$COLOR_DIM" "$COLOR_RESET"
        fi
        ;;
      item)
        if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
          if [[ $idx -eq $focus_idx ]]; then
            printf '%*s%b%d. %s%b\n' "$_UI_COMPACT_INDENT" '' "$COLOR_CYAN" "$((idx + 1))" "${items[$idx]}" "$COLOR_RESET"
          else
            printf '%*s%d. %s\n' "$_UI_COMPACT_INDENT" '' "$((idx + 1))" "${items[$idx]}"
          fi
        else
          if [[ $idx -eq $focus_idx ]]; then
            printf '%*s%b> %s%b\n' "$_UI_BREAD_INDENT" '' "$COLOR_CYAN" "${items[$idx]}" "$COLOR_RESET"
          else
            printf '%*s%s\n' "$_UI_ITEM_INDENT" '' "${items[$idx]}"
          fi
        fi
        ;;
    esac
  }

  # ---- 局部刷新：焦点移动（仅重写旧行和新行） ----
  # 若滚动偏移变化导致旧焦点不可见，则回退到全量重绘
  _ui_menu_move_focus() {
    local old_idx=$1 new_idx=$2

    if ! _ui_menu_item_visible "$old_idx"; then
      # 旧焦点已不可见（如 NUM 跳转或循环 wrap）→ 全量重绘
      _ui_menu_render_all
      printf '\033[s'
      _UI_CURSOR_SAVED=1
      return
    fi

    local old_item_line new_item_line
    old_item_line=$(_item_to_line "$old_idx")
    new_item_line=$(_item_to_line "$new_idx")

    printf '\033[u'
    _ui_menu_draw_line "$old_item_line" "item" "$old_idx"
    printf '\033[u'
    _ui_menu_draw_line "$new_item_line" "item" "$new_idx"
    printf '\033[u'
  }

  # ---- 全量重绘辅助（更新 total_lines + 渲染 + 保存光标） ----
  _ui_menu_full_redraw() {
    _ui_menu_calc_visible
    _ui_menu_clamp_scroll
    if [[ $_ui_needs_scroll -eq 0 ]]; then
      total_lines=$(( breadcrumb_lines + item_count + bottom_lines ))
    else
      total_lines=$(( breadcrumb_lines + _ui_top_ind + _ui_visible_slots + _ui_bot_ind + bottom_lines ))
    fi
    _ui_menu_render_all
    printf '\033[s'
    _UI_CURSOR_SAVED=1
  }

  # ═══════════════ 首次渲染 ═══════════════
  _ui_menu_full_redraw
  if [[ -n "$breadcrumb" ]]; then
    _ui_a11y_announce "子菜单: ${breadcrumb}，共 ${item_count} 项，当前焦点: ${items[$focus_idx]}"
  else
    _ui_a11y_announce "主菜单，共 ${item_count} 项，当前焦点: ${items[$focus_idx]}"
  fi

  # ═══════════════ 主循环 ═══════════════
  while true; do
    local key
    read_key || { _UI_MENU_SNAPSHOT_FOCUSED=$focus_idx; return 254; }
    key="$_READ_KEY_RESULT"

    case "$key" in
      REDRAW)
        _UI_NEEDS_REDRAW=0
        # 重新计算布局参数（紧凑模式可能随 ui_screen_init 更新，但不在 SIGWINCH 中变化）
        breadcrumb_lines=0
        if [[ -n "$breadcrumb" ]]; then
          if [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]]; then
            breadcrumb_lines=1
          else
            breadcrumb_lines=2
          fi
        fi
        _ui_menu_full_redraw
        _ui_a11y_announce "屏幕已刷新，焦点: ${items[$focus_idx]} ($((focus_idx + 1))/${item_count})"
        ;;
      UP)
        old_focus=$focus_idx
        if [[ $focus_idx -gt 0 ]]; then
          ((focus_idx--)) || true
        else
          focus_idx=$((item_count - 1))  # 循环到末项（§5.1）
        fi
        _ui_menu_clamp_scroll
        _ui_menu_calc_visible
        # 若指示器变化（边界情况），全量重绘
        if [[ $_ui_needs_scroll -eq 1 ]]; then
          total_lines=$(( breadcrumb_lines + _ui_top_ind + _ui_visible_slots + _ui_bot_ind + bottom_lines ))
        fi
        _ui_menu_move_focus "$old_focus" "$focus_idx"
        _ui_a11y_announce "焦点: ${items[$focus_idx]} ($((focus_idx + 1))/${item_count})"
        ;;
      DOWN)
        old_focus=$focus_idx
        if [[ $focus_idx -lt $((item_count - 1)) ]]; then
          ((focus_idx++)) || true
        else
          focus_idx=0  # 循环到首项（§5.1）
        fi
        _ui_menu_clamp_scroll
        _ui_menu_calc_visible
        if [[ $_ui_needs_scroll -eq 1 ]]; then
          total_lines=$(( breadcrumb_lines + _ui_top_ind + _ui_visible_slots + _ui_bot_ind + bottom_lines ))
        fi
        _ui_menu_move_focus "$old_focus" "$focus_idx"
        _ui_a11y_announce "焦点: ${items[$focus_idx]} ($((focus_idx + 1))/${item_count})"
        ;;
      ENTER)
        _UI_MENU_SNAPSHOT_FOCUSED=$focus_idx
        if [[ -n "${UI_MENU_RESULT_FILE:-}" ]]; then
          echo "$focus_idx" > "$UI_MENU_RESULT_FILE"
        else
          echo "$focus_idx"
        fi
        return 0
        ;;
      ESC)
        if [[ -n "$back_label" ]]; then
          _UI_MENU_SNAPSHOT_FOCUSED=$focus_idx
          return 254
        fi
        ;;
      Q)
        if [[ "$enable_quit" -eq 1 ]]; then
          _UI_MENU_SNAPSHOT_FOCUSED=$focus_idx
          return 255
        fi
        ;;
      NUM:*)
        local num="${key#NUM:}"
        local idx=$(( num - 1 ))
        if [[ $idx -ge 0 && $idx -lt $item_count ]]; then
          old_focus=$focus_idx
          focus_idx=$idx
          _ui_menu_clamp_scroll
          _ui_menu_calc_visible
          if [[ $_ui_needs_scroll -eq 1 ]]; then
            total_lines=$(( breadcrumb_lines + _ui_top_ind + _ui_visible_slots + _ui_bot_ind + bottom_lines ))
          fi
          _ui_menu_move_focus "$old_focus" "$focus_idx"
          _ui_a11y_announce "跳转至: ${items[$focus_idx]} ($((focus_idx + 1))/${item_count})"
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

 
