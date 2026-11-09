#!/bin/bash
# 功能：对话框组件 — 确认框 / 提示框 / 文本输入
# 说明：纯 Bash + ANSI 实现，不依赖 dialog/whiptail
#       渲染写入 /dev/tty，结果返回到 stdout（适配管道调用）
# 依赖：lib/ui/menu.sh（read_key）、lib/core/colors.sh、lib/core/logging.sh
#
# 用法：
#   result=$(ui_confirm "确定要卸载 Docker 吗？" "将移除所有容器和镜像。")
#   ui_alert "当前系统不是 Debian 12+"
#   hostname=$(ui_input "请输入主机名" "debnas")

set -euo pipefail
IFS=$'\n\t'

# ═══════════════════════════════════════════════════════════════
# 确认对话框
# ═══════════════════════════════════════════════════════════════

# 确认对话框（危险操作前确认）
# 参数：$1 — 标题（操作描述）
#       $2 — 辅助说明（可选，多行用 \n 分隔）
# 输出 (stdout)：0 (确认) / 1 (取消)
# 退出码：0=正常返回, 1=非交互降级
# 交互：Y/y 确认，N/n 取消，←→ 切换焦点，Enter 确认当前焦点
#       默认焦点在 [N] 取消（安全默认）
ui_confirm() {
  local title="$1"
  local description="${2:-}"

  # 非交互模式：仅 DEBNAS_FORCE_YES=1 时自动确认，否则拒绝（安全默认）
  if [[ ! -t 0 ]]; then
    if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
      echo "0"
    else
      echo "1"
    fi
    return 0
  fi
  if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
    echo "0"
    return 0
  fi
  _ui_terminal_echo_off

  # 焦点：0=[Y]确认, 1=[N]取消，默认在 N
  local focus=1

  _ui_confirm_render() {
    local y_style n_style
    if [[ $focus -eq 0 ]]; then
      y_style="${COLOR_CYAN}"
      n_style="${COLOR_RESET}"
    else
      y_style="${COLOR_RESET}"
      n_style="${COLOR_CYAN}"
    fi

    # 标题
    printf '\n' > /dev/tty
    printf '    %s\n' "$title" > /dev/tty
    printf '\n' > /dev/tty

    # 辅助说明（多行）
    if [[ -n "$description" ]]; then
      # 逐行读取而非 for line in $description：未加引号的展开会做路径名扩展，
      # 说明文字里的 "*"（如 /var/lib/docker/*）会被替换成真实文件名
      local line
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%b    %s%b\n' "$COLOR_DIM" "$line" "$COLOR_RESET" > /dev/tty
      done <<< "$description"
      printf '\n' > /dev/tty
    fi

    # 操作按钮
    printf '    %b[Y] 确认%b          %b[N] 取消%b\n' \
      "$y_style" "$COLOR_RESET" "$n_style" "$COLOR_RESET" > /dev/tty
    printf '\n' > /dev/tty
  }

  _ui_confirm_render

  # 无障碍播报
  _ui_a11y_announce "确认对话框: ${title}。Y 确认，N 取消，默认焦点在取消。"

  # 保存起始位置（用于局部刷新）
  printf '\033[s' > /dev/tty

  local key
  while true; do
    read_key < /dev/tty || {
      _ui_terminal_echo_on
      echo "1"
      return 0
    }
    key="$_READ_KEY_RESULT"

    case "$key" in
      REDRAW)
        _UI_NEEDS_REDRAW=0
        ui_detect_size 2>/dev/null || true
        _ui_confirm_render
        printf '\033[s' > /dev/tty
        ;;
      LEFT)
        if [[ $focus -eq 1 ]]; then
          focus=0
          printf '\033[u' > /dev/tty
          _ui_confirm_render
          printf '\033[u' > /dev/tty
        fi
        ;;
      RIGHT)
        if [[ $focus -eq 0 ]]; then
          focus=1
          printf '\033[u' > /dev/tty
          _ui_confirm_render
          printf '\033[u' > /dev/tty
        fi
        ;;
      ENTER)
        _ui_terminal_echo_on
        echo "$focus"
        return 0
        ;;
      OTHER:y|OTHER:Y)
        focus=0
        # 局部刷新显示焦点变化
        printf '\033[u' > /dev/tty
        _ui_confirm_render
        _ui_terminal_echo_on
        echo "0"
        return 0
        ;;
      OTHER:n|OTHER:N)
        focus=1
        printf '\033[u' > /dev/tty
        _ui_confirm_render
        _ui_terminal_echo_on
        echo "1"
        return 0
        ;;
      ESC)
        _ui_terminal_echo_on
        echo "1"
        return 0
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# 信息提示框
# ═══════════════════════════════════════════════════════════════

# 信息提示框（阻断式通知）
# 参数：$1 — 标题
#       $2 — 辅助说明（可选，多行用 \n 分隔）
# 退出码：0
# 交互：Enter 关闭
ui_alert() {
  local title="$1"
  local description="${2:-}"

  # 非交互模式：直接返回
  if [[ ! -t 0 ]]; then
    return 0
  fi
  _ui_terminal_echo_off

  printf '\n' > /dev/tty
  printf '    %s\n' "$title" > /dev/tty
  printf '\n' > /dev/tty

  if [[ -n "$description" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '%b    %s%b\n' "$COLOR_DIM" "$line" "$COLOR_RESET" > /dev/tty
    done <<< "$description"
    printf '\n' > /dev/tty
  fi

  printf '%b    Enter 关闭%b\n' "$COLOR_DIM" "$COLOR_RESET" > /dev/tty
  printf '\n' > /dev/tty

  # 无障碍播报
  _ui_a11y_announce "提示: ${title}。Enter 关闭。"

  # 等待 Enter
  local key
  while true; do
    read_key < /dev/tty || {
      _ui_terminal_echo_on
      return 0
    }
    key="$_READ_KEY_RESULT"
    case "$key" in
      REDRAW)
        _UI_NEEDS_REDRAW=0
        ui_detect_size 2>/dev/null || true
        # 重绘 alert
        printf '\n' > /dev/tty
        printf '    %s\n' "$title" > /dev/tty
        printf '\n' > /dev/tty
        if [[ -n "$description" ]]; then
          local line
          while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf '%b    %s%b\n' "$COLOR_DIM" "$line" "$COLOR_RESET" > /dev/tty
          done <<< "$description"
          printf '\n' > /dev/tty
        fi
        printf '%b    Enter 关闭%b\n' "$COLOR_DIM" "$COLOR_RESET" > /dev/tty
        printf '\n' > /dev/tty
        ;;
      ENTER|ESC|Q)
        _ui_terminal_echo_on
        return 0
        ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════
# 文本输入框
# ═══════════════════════════════════════════════════════════════

# 文本输入框
# 参数：$1 — 提示文字
#       $2 — 默认值（可选）
#       $3 — "hidden" 隐藏回显（密码输入，可选）
# 输出 (stdout)：用户输入的文本
# 退出码：0=正常输入, 1=非交互降级
ui_input() {
  local prompt="$1"
  local default="${2:-}"
  local hidden="${3:-}"

  # 非交互模式：读取 stdin；EOF 或空行回退到默认值
  if [[ ! -t 0 ]]; then
    local input
    if IFS= read -r input; then
      if [[ -n "$input" ]]; then
        echo "$input"
      else
        echo "$default"
      fi
    elif [[ -n "$default" ]]; then
      echo "$default"
    fi
    return 0
  fi

  printf '\n' > /dev/tty
  if [[ -n "$default" ]]; then
    printf '    %s [%b%s%b]: ' "$prompt" "$COLOR_DIM" "$default" "$COLOR_RESET" > /dev/tty
  else
    printf '    %s: ' "$prompt" > /dev/tty
  fi

  # 无障碍播报
  local a11y_type="输入"
  [[ "$hidden" == "hidden" ]] && a11y_type="密码输入"
  if [[ -n "$default" ]]; then
    _ui_a11y_announce "${a11y_type}: ${prompt}，默认值: ${default}"
  else
    _ui_a11y_announce "${a11y_type}: ${prompt}"
  fi

  local input
  if [[ "$hidden" == "hidden" ]]; then
    IFS= read -rs input < /dev/tty || {
      printf '\n' > /dev/tty
      if [[ -n "$default" ]]; then
        echo "$default"
      fi
      return 0
    }
    printf '\n' > /dev/tty
  else
    IFS= read -r input < /dev/tty || {
      # EOF — 返回默认值
      if [[ -n "$default" ]]; then
        echo "$default"
      fi
      return 0
    }
  fi

  # 空输入 → 默认值
  if [[ -z "$input" && -n "$default" ]]; then
    echo "$default"
    return 0
  fi

  echo "$input"
  return 0
}
