#!/bin/bash
# 功能：终端显示宽度工具 — 计算/截断/补齐含中文的字符串
# 说明：纯 Bash 实现（不依赖 wcwidth 外部程序），供仪表盘边框对齐使用
#       要求当前 LC_CTYPE 为 UTF-8（${#s} 按字符计数、printf "'c" 取码点）；
#       非 UTF-8 locale 下退化为按字节计宽（仪表盘入口会先保证 UTF-8，见 ui_utf8_ensure）
# 宽度规则：
#   - 可打印 ASCII 占 1 列
#   - East Asian Wide/Fullwidth（CJK 汉字、假名、全角标点、韩文、部分 emoji 如 ⚡）占 2 列
#   - 组合附加符、零宽字符、变体选择符占 0 列
#   - 其余（box-drawing、● ○ ✓ ⚠ ✖ … 等）占 1 列（East Asian Ambiguous 按西文终端处理）
# 输出约定：主函数写入全局变量（_UI_W / _UI_FIT），避免命令替换产生子 shell；
#           ui_str_width_echo / ui_str_fit_echo 为测试与脚本调用提供 stdout 版本

set -euo pipefail
IFS=$'\n\t'

declare -g _UI_W=0
declare -g _UI_FIT=""

# 判断码点是否为双宽字符
# 参数：$1 — 十进制码点
# 返回：0 双宽，1 否
_ui_cp_is_wide() {
  local cp=$1
  (( cp < 0x1100 )) && return 1
  if (( cp <= 0x115F )) \
    || (( cp >= 0x231A && cp <= 0x231B )) \
    || (( cp >= 0x2329 && cp <= 0x232A )) \
    || (( cp >= 0x23E9 && cp <= 0x23EC )) || (( cp == 0x23F0 || cp == 0x23F3 )) \
    || (( cp >= 0x25FD && cp <= 0x25FE )) \
    || (( cp >= 0x2614 && cp <= 0x2615 )) \
    || (( cp >= 0x2648 && cp <= 0x2653 )) \
    || (( cp == 0x267F || cp == 0x2693 || cp == 0x26A1 )) \
    || (( cp >= 0x26AA && cp <= 0x26AB )) || (( cp >= 0x26BD && cp <= 0x26BE )) \
    || (( cp >= 0x26C4 && cp <= 0x26C5 )) || (( cp == 0x26CE || cp == 0x26D4 || cp == 0x26EA )) \
    || (( cp >= 0x26F2 && cp <= 0x26F3 )) || (( cp == 0x26F5 || cp == 0x26FA || cp == 0x26FD )) \
    || (( cp == 0x2705 )) || (( cp >= 0x270A && cp <= 0x270B )) || (( cp == 0x2728 )) \
    || (( cp == 0x274C || cp == 0x274E )) || (( cp >= 0x2753 && cp <= 0x2755 )) || (( cp == 0x2757 )) \
    || (( cp >= 0x2795 && cp <= 0x2797 )) || (( cp == 0x27B0 || cp == 0x27BF )) \
    || (( cp >= 0x2B1B && cp <= 0x2B1C )) || (( cp == 0x2B50 || cp == 0x2B55 )) \
    || (( cp >= 0x2E80 && cp <= 0x303E )) \
    || (( cp >= 0x3041 && cp <= 0x33FF )) \
    || (( cp >= 0x3400 && cp <= 0x4DBF )) \
    || (( cp >= 0x4E00 && cp <= 0x9FFF )) \
    || (( cp >= 0xA000 && cp <= 0xA4CF )) \
    || (( cp >= 0xA960 && cp <= 0xA97F )) \
    || (( cp >= 0xAC00 && cp <= 0xD7A3 )) \
    || (( cp >= 0xF900 && cp <= 0xFAFF )) \
    || (( cp >= 0xFE10 && cp <= 0xFE19 )) \
    || (( cp >= 0xFE30 && cp <= 0xFE6F )) \
    || (( cp >= 0xFF00 && cp <= 0xFF60 )) \
    || (( cp >= 0xFFE0 && cp <= 0xFFE6 )) \
    || (( cp >= 0x1F300 && cp <= 0x1F64F )) \
    || (( cp >= 0x1F680 && cp <= 0x1F6FF )) \
    || (( cp >= 0x1F900 && cp <= 0x1F9FF )) \
    || (( cp >= 0x20000 && cp <= 0x3FFFD )); then
    return 0
  fi
  return 1
}

# 判断码点是否为零宽字符（组合附加符/零宽空格/变体选择符）
# 参数：$1 — 十进制码点
# 返回：0 零宽，1 否
_ui_cp_is_zero() {
  local cp=$1
  (( cp >= 0x0300 && cp <= 0x036F )) && return 0
  (( cp >= 0x200B && cp <= 0x200F )) && return 0
  (( cp >= 0xFE00 && cp <= 0xFE0F )) && return 0
  return 1
}

# 计算单个字符的显示宽度
# 参数：$1 — 单个字符
# 输出：全局 _UI_W（0/1/2）
_ui_char_width() {
  local c="$1" cp
  if [[ "$c" == [\ -~] ]]; then
    _UI_W=1
    return 0
  fi
  printf -v cp '%d' "'$c" 2>/dev/null || cp=63
  if _ui_cp_is_zero "$cp"; then
    _UI_W=0
  elif _ui_cp_is_wide "$cp"; then
    _UI_W=2
  else
    _UI_W=1
  fi
}

# 计算字符串显示宽度
# 参数：$1 — 字符串（不得包含 ANSI 转义序列）
# 输出：全局 _UI_W
ui_str_width() {
  local s="${1:-}"
  local w=${#s}
  # 快速路径：剔除可打印 ASCII 后为空 → 宽度即字符数
  local rest="${s//[ -~]/}"
  if [[ -n "$rest" ]]; then
    local i n=${#rest} c cp
    for (( i = 0; i < n; i++ )); do
      c="${rest:i:1}"
      printf -v cp '%d' "'$c" 2>/dev/null || continue
      if _ui_cp_is_zero "$cp"; then
        (( w-- )) || true
      elif _ui_cp_is_wide "$cp"; then
        (( w++ )) || true
      fi
    done
  fi
  _UI_W=$w
}

# 将字符串截断/补齐到指定显示宽度（超长截断并以 … 结尾，不足补空格）
# 参数：$1 — 字符串
#       $2 — 目标宽度（列）
#       $3 — 对齐方式（可选：left 默认 / right）
# 输出：全局 _UI_FIT（显示宽度恰好等于目标宽度）
ui_str_fit() {
  local s="${1:-}" width="${2:-0}" align="${3:-left}"
  if (( width <= 0 )); then
    _UI_FIT=""
    return 0
  fi
  ui_str_width "$s"
  local w=$_UI_W
  if (( w > width )); then
    # 截断：保留宽度 width-1 的前缀，再追加 …（占 1 列）
    local limit=$(( width - 1 )) acc=0 i n=${#s} c out=""
    if [[ -z "${s//[ -~]/}" ]]; then
      out="${s:0:limit}"
      acc=${#out}
    else
      for (( i = 0; i < n; i++ )); do
        c="${s:i:1}"
        _ui_char_width "$c"
        (( acc + _UI_W > limit )) && break
        out+="$c"
        (( acc += _UI_W )) || true
      done
    fi
    s="${out}…"
    w=$(( acc + 1 ))
  fi
  local pad=$(( width - w ))
  if (( pad > 0 )); then
    local spaces
    printf -v spaces '%*s' "$pad" ''
    if [[ "$align" == "right" ]]; then
      s="${spaces}${s}"
    else
      s="${s}${spaces}"
    fi
  fi
  _UI_FIT="$s"
}

# 按显示宽度折行（用于详情说明）
# 参数：$1 — 字符串，$2 — 每行最大宽度，$3 — 最多行数
# 输出：全局数组 _UI_WRAP（每元素一行，未补齐）；超出最多行数时末行以 … 结尾
declare -g -a _UI_WRAP=()
ui_str_wrap() {
  local s="${1:-}" width="${2:-1}" max_lines="${3:-2}"
  _UI_WRAP=()
  (( width < 2 )) && width=2
  local line="" acc=0 i n=${#s} c
  for (( i = 0; i < n; i++ )); do
    c="${s:i:1}"
    _ui_char_width "$c"
    if (( acc + _UI_W > width )); then
      _UI_WRAP+=("$line")
      line="" acc=0
      if (( ${#_UI_WRAP[@]} >= max_lines )); then
        # 超出：把最后一行替换为截断版本
        ui_str_fit "${_UI_WRAP[max_lines - 1]}${s:i}" "$width"
        local last="${_UI_FIT%"${_UI_FIT##*[! ]}"}"
        _UI_WRAP[max_lines - 1]="$last"
        return 0
      fi
      # 行首不保留空格
      [[ "$c" == " " ]] && continue
    fi
    line+="$c"
    (( acc += _UI_W )) || true
  done
  [[ -n "$line" ]] && _UI_WRAP+=("$line")
  return 0
}

# 重复字符串 n 次
# 参数：$1 — 字符串，$2 — 次数
# 输出：全局 _UI_FIT
ui_str_repeat() {
  local s="$1" n="${2:-0}" out=""
  (( n > 0 )) || { _UI_FIT=""; return 0; }
  local spaces
  printf -v spaces '%*s' "$n" ''
  out="${spaces// /$s}"
  _UI_FIT="$out"
}

# 去除控制字符（含 ESC），防止外部文本（模块输出）破坏终端布局
# 参数：$1 — 字符串
# 输出：stdout
ui_str_sanitize() {
  local s="${1:-}"
  s="${s//$'\t'/ }"
  s="${s//[$'\001'-$'\037'$'\177']/}"
  printf '%s' "$s"
}

# stdout 版本（测试/脚本使用）
ui_str_width_echo() { ui_str_width "${1:-}"; printf '%s\n' "$_UI_W"; }
ui_str_fit_echo() { ui_str_fit "${1:-}" "${2:-0}" "${3:-left}"; printf '%s\n' "$_UI_FIT"; }

# 确保当前 shell 使用 UTF-8 字符语义（仪表盘依赖）
# 当前 locale 非 UTF-8 时尝试切到 C.UTF-8（Debian 自带）；原值保存在 _UI_SAVED_LOCALE_* 供子进程恢复
# 返回：0 已是/已切到 UTF-8，1 无法获得 UTF-8 语义
ui_utf8_ensure() {
  local probe='中'
  if [[ ${#probe} -eq 1 ]]; then
    return 0
  fi
  declare -g _UI_SAVED_LC_ALL="${LC_ALL-__unset__}" _UI_SAVED_LC_CTYPE="${LC_CTYPE-__unset__}"
  LC_ALL=C.UTF-8
  LC_CTYPE=C.UTF-8
  probe='中'
  [[ ${#probe} -eq 1 ]]
}

# 恢复 ui_utf8_ensure 之前的 locale（执行模块前调用，避免改变模块输出语言）
ui_utf8_restore() {
  [[ -n "${_UI_SAVED_LC_ALL:-}" ]] || return 0
  if [[ "$_UI_SAVED_LC_ALL" == "__unset__" ]]; then unset LC_ALL; else LC_ALL="$_UI_SAVED_LC_ALL"; fi
  if [[ "$_UI_SAVED_LC_CTYPE" == "__unset__" ]]; then unset LC_CTYPE; else LC_CTYPE="$_UI_SAVED_LC_CTYPE"; fi
  return 0
}
