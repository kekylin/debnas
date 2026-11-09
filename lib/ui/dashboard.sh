#!/bin/bash
# 功能：方案 A 双栏 TUI 仪表盘（交互菜单默认界面，2026-11-09 起）
# 说明：
#   - 布局：顶部系统信息框 / 左栏分类 / 右栏功能列表（勾选+状态+说明）/ 执行计划·预演框 / 快捷键行
#   - 窄终端（< 100 列或 < 28 行）自动退化为单栏两级（分类 → 功能），仍有状态列、多选、预演
#   - 渲染：每帧在内存中合成整屏（_DASH_FRAME），与上一帧逐行比对，只重写变化的行（无全屏 clear，无闪烁）
#   - 终端：备用屏幕（alt screen）+ 隐藏光标 + stty -echo -icanon；EXIT/INT 时恢复；SIGWINCH 重新布局
#   - 状态：进入时异步并行采集全部模块 module_status（lib/system/module-probe.sh），执行后只刷新执行过的模块
#   - 执行：离开全屏 → 打印完整预演并确认 → 逐个调用 bin/module-runner.sh 流式输出 → 汇总 → 按键返回
#   - 回退：非 TTY、TERM=dumb、DEBNAS_UI=classic 或无法获得 UTF-8 语义时，由 bin/menu.sh 走旧版 ui_menu 界面
# 依赖：textwidth.sh、sysinfo.sh、module-registry.sh、module-probe.sh、state.sh、logging.sh
#       bin/menu.sh 中的 SOLUTION_NAMES / SOLUTION_DISPLAY_NAMES（load_solutions）

set -euo pipefail
IFS=$'\n\t'

# ═══════════════════════════════════════════════════════════════
# 常量与状态
# ═══════════════════════════════════════════════════════════════

readonly DASH_MIN_WIDE_COLS=100
readonly DASH_MIN_WIDE_ROWS=28
readonly DASH_MIN_COLS=40
readonly DASH_MIN_ROWS=14
readonly DASH_SOL_CATEGORY="⚡ 一键部署"

# 模型
declare -g -a _DASH_CAT_NAME=() _DASH_CAT_KIND=() _DASH_CAT_FIRST=() _DASH_CAT_LEN=()
declare -g -a _DASH_KEYS_ALL=()
declare -g -A _DASH_ITEM_NAME=() _DASH_ITEM_DESC=() _DASH_ITEM_MODS=() _DASH_SEL=()
declare -g -a _DASH_LIST=()

# 交互状态
declare -g _DASH_CAT=0 _DASH_PANE=0 _DASH_FOCUS=0 _DASH_SCROLL=0 _DASH_CSCROLL=0
declare -g _DASH_SEARCH_MODE=0 _DASH_QUERY=""
declare -g _DASH_OVERLAY="" _DASH_OVERLAY_OFF=0
declare -g -a _DASH_OVERLAY_LINES=()
declare -g _DASH_MSG="" _DASH_QUIT=0 _DASH_RESIZED=0 _DASH_KEY=""

# 预演
declare -g -a _DASH_PLAN=()
declare -g _DASH_PLAN_SIG="" _DASH_PLAN_RISKS=0

# 布局与帧
declare -g _DASH_COLS=80 _DASH_ROWS=24 _DASH_W=79 _DASH_MODE="wide"
declare -g -a _DASH_FRAME=() _DASH_PREV=()
declare -g _DASH_L="" _DASH_SIG="" _DASH_DESC=""
declare -g _DASH_TUI_ON=0 _DASH_STTY="" _DASH_DIR="" _DASH_RUNNER=""
declare -g _DASH_LAST_SAMPLE=0 _DASH_LAST_DISK=0

# 颜色（8 色 ANSI；NO_COLOR 时为空，焦点行改用反显属性）
declare -g _DC_RESET="" _DC_DIM="" _DC_ACC="" _DC_OK="" _DC_WARN="" _DC_BAD="" _DC_SEL="" _DC_KEY="" _DC_BORDER=""

_dash_init_colors() {
  if [[ -n "${NO_COLOR:-}" && "${NO_COLOR}" != "0" ]]; then
    _DC_RESET=$'\e[0m' _DC_DIM="" _DC_ACC="" _DC_OK="" _DC_WARN="" _DC_BAD=""
    _DC_SEL=$'\e[7m' _DC_KEY="" _DC_BORDER=""
  else
    _DC_RESET=$'\e[0m'
    _DC_DIM=$'\e[90m'
    _DC_ACC=$'\e[36m'
    _DC_OK=$'\e[32m'
    _DC_WARN=$'\e[33m'
    _DC_BAD=$'\e[31m'
    _DC_SEL=$'\e[44m'
    _DC_KEY=$'\e[30;47m'
    _DC_BORDER=$'\e[90m'
  fi
}

# ═══════════════════════════════════════════════════════════════
# 入口判定
# ═══════════════════════════════════════════════════════════════

# 是否可以使用仪表盘（否则调用方回退旧版 ui_menu）
# 返回：0 可用，1 不可用
ui_dashboard_available() {
  [[ "${DEBNAS_UI:-}" == "classic" ]] && return 1
  [[ -t 0 && -t 1 ]] || return 1
  case "${TERM:-dumb}" in dumb|"") return 1 ;; esac
  ui_utf8_ensure || return 1
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 模型构建
# ═══════════════════════════════════════════════════════════════

# 读取模块说明到全局 _DASH_DESC：优先 @description，其次文件头 "# 功能：..." 注释（不 fork）
_dash_module_desc_get() {
  local module_name="$1" path="" line n=0
  _DASH_DESC=""
  get_module_field_var _DASH_DESC "$module_name" "description" || _DASH_DESC=""
  if [[ -z "$_DASH_DESC" ]]; then
    get_module_field_var path "$module_name" "path" || path=""
    if [[ -n "$path" && -r "$path" ]]; then
      while IFS= read -r line && (( n++ < 20 )); do
        if [[ "$line" =~ ^#[[:space:]]*功能[:：][[:space:]]*(.*)$ ]]; then
          _DASH_DESC="${BASH_REMATCH[1]}"
          break
        fi
      done < "$path"
    fi
  fi
  return 0
}

# 读取方案文件中的模块列表（每行一个，忽略注释/空行）
_dash_solution_modules() {
  local file="$1" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$file"
}

# 构建分类与条目模型（第一个分类为一键部署）
_dash_build_model() {
  local IFS=$'\n\t'
  _DASH_CAT_NAME=() _DASH_CAT_KIND=() _DASH_CAT_FIRST=() _DASH_CAT_LEN=() _DASH_KEYS_ALL=()
  _DASH_ITEM_NAME=() _DASH_ITEM_DESC=() _DASH_ITEM_MODS=()
  local i key mods m names start mname

  # 一键部署
  if [[ ${#SOLUTION_NAMES[@]} -gt 0 ]]; then
    start=${#_DASH_KEYS_ALL[@]}
    for i in "${!SOLUTION_NAMES[@]}"; do
      key="s:${SOLUTION_NAMES[$i]}"
      mods=$(_dash_solution_modules "${_DASH_ROOT}/config/solutions/${SOLUTION_NAMES[$i]}.list")
      _DASH_ITEM_NAME["$key"]="${SOLUTION_DISPLAY_NAMES[$i]}"
      _DASH_ITEM_MODS["$key"]="$mods"
      names=""
      for m in $mods; do
        get_module_field_var mname "$m" "name" "$m" || mname="$m"
        names+="${names:+ → }${mname}"
      done
      _DASH_ITEM_DESC["$key"]="依次执行：${names:-（空方案）}"
      _DASH_KEYS_ALL+=("$key")
    done
    _DASH_CAT_NAME+=("$DASH_SOL_CATEGORY")
    _DASH_CAT_KIND+=("sol")
    _DASH_CAT_FIRST+=("$start")
    _DASH_CAT_LEN+=("$(( ${#_DASH_KEYS_ALL[@]} - start ))")
  fi

  # 模块分类（沿用 CATEGORY_ORDER，跳过空分类与"一键部署"占位）
  local category
  local -a modules
  for category in "${CATEGORY_ORDER[@]}"; do
    [[ "$category" == "一键部署" ]] && continue
    mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
    [[ ${#modules[@]} -gt 0 && -n "${modules[0]}" ]] || continue
    start=${#_DASH_KEYS_ALL[@]}
    for m in "${modules[@]}"; do
      [[ -n "$m" ]] || continue
      key="m:${m}"
      get_module_field_var mname "$m" "name" "$m" || mname="$m"
      _DASH_ITEM_NAME["$key"]="$mname"
      _dash_module_desc_get "$m"
      _DASH_ITEM_DESC["$key"]="$_DASH_DESC"
      _DASH_KEYS_ALL+=("$key")
    done
    _DASH_CAT_NAME+=("$category")
    _DASH_CAT_KIND+=("mod")
    _DASH_CAT_FIRST+=("$start")
    _DASH_CAT_LEN+=("$(( ${#_DASH_KEYS_ALL[@]} - start ))")
  done
  [[ ${#_DASH_CAT_NAME[@]} -gt 0 ]]
}

# 计算当前右栏列表（分类或搜索结果）
_dash_build_list() {
  _DASH_LIST=()
  if (( _DASH_SEARCH_MODE > 0 )); then
    local q="${_DASH_QUERY,,}" key hay
    [[ -n "$q" ]] || return 0
    for key in "${_DASH_KEYS_ALL[@]}"; do
      hay="${key#*:} ${_DASH_ITEM_NAME[$key]} ${_DASH_ITEM_DESC[$key]}"
      hay="${hay,,}"
      [[ "$hay" == *"$q"* ]] && _DASH_LIST+=("$key")
    done
  elif [[ ${#_DASH_CAT_NAME[@]} -gt 0 ]]; then
    _DASH_LIST=("${_DASH_KEYS_ALL[@]:${_DASH_CAT_FIRST[$_DASH_CAT]}:${_DASH_CAT_LEN[$_DASH_CAT]}}")
  fi
  local n=${#_DASH_LIST[@]}
  (( _DASH_FOCUS >= n )) && _DASH_FOCUS=$(( n > 0 ? n - 1 : 0 ))
  (( _DASH_FOCUS < 0 )) && _DASH_FOCUS=0
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 状态视图
# ═══════════════════════════════════════════════════════════════

# 取条目状态：设置 _DASH_ST_CODE / _DASH_ST_DESC
_dash_item_status() {
  local IFS=$'\n\t'
  local key="$1" r
  if [[ "$key" == m:* ]]; then
    r="${_MODULE_STATUS[${key#m:}]:-pending|检测中}"
    _DASH_ST_CODE="${r%%|*}"
    _DASH_ST_DESC="${r#*|}"
    return 0
  fi
  # 方案：由成员模块状态汇总
  local m total=0 done_n=0 pending=0 code
  for m in ${_DASH_ITEM_MODS[$key]:-}; do
    total=$(( total + 1 ))
    r="${_MODULE_STATUS[$m]:-pending|}"
    code="${r%%|*}"
    case "$code" in
      applied|running) done_n=$(( done_n + 1 )) ;;
      pending) pending=1 ;;
    esac
  done
  if (( pending )); then
    _DASH_ST_CODE="pending"; _DASH_ST_DESC="检测中"
  elif (( total > 0 && done_n == total )); then
    _DASH_ST_CODE="applied"; _DASH_ST_DESC="${total} 个模块均已完成"
  elif (( done_n > 0 )); then
    _DASH_ST_CODE="partial"; _DASH_ST_DESC="${done_n}/${total} 个模块已完成"
  else
    _DASH_ST_CODE="absent"; _DASH_ST_DESC="${total} 个模块均未完成"
  fi
}

# 状态码 → 显示文本与颜色：设置 _DASH_SV_TEXT / _DASH_SV_COLOR
# 参数：$1 状态码；$2 状态说明、$3 模块名（可选，仅用于区分 absent 显示"未安装"还是"未配置"）
# absent 文案：模块声明 @kind: install|config 时按声明；未声明时说明以"未安装"开头（或为空）→ 未安装，否则 → 未配置
_dash_status_view() {
  if [[ "$1" == "absent" ]]; then
    local kind=""
    [[ -n "${3:-}" ]] && { get_module_field_var kind "$3" "kind" || kind=""; }
    case "$kind" in
      install) _DASH_SV_TEXT="○ 未安装" ;;
      config)  _DASH_SV_TEXT="○ 未配置" ;;
      *) if [[ -z "${2:-}" || "$2" == 未安装* ]]; then _DASH_SV_TEXT="○ 未安装"; else _DASH_SV_TEXT="○ 未配置"; fi ;;
    esac
    _DASH_SV_COLOR="$_DC_DIM"
    return 0
  fi
  case "$1" in
    applied) _DASH_SV_TEXT="● 已应用";   _DASH_SV_COLOR="$_DC_OK" ;;
    running) _DASH_SV_TEXT="● 运行中";   _DASH_SV_COLOR="$_DC_OK" ;;
    partial) _DASH_SV_TEXT="◐ 部分完成"; _DASH_SV_COLOR="$_DC_WARN" ;;
    warn)    _DASH_SV_TEXT="⚠ 需注意";   _DASH_SV_COLOR="$_DC_WARN" ;;
    error)   _DASH_SV_TEXT="✖ 异常";     _DASH_SV_COLOR="$_DC_BAD" ;;
    pending) _DASH_SV_TEXT="… 检测中";   _DASH_SV_COLOR="$_DC_DIM" ;;
    *)       _DASH_SV_TEXT="? 未知";     _DASH_SV_COLOR="$_DC_DIM" ;;
  esac
}

# 分类完成度：设置 _DASH_CNT_TEXT / _DASH_CNT_COLOR
_dash_cat_count() {
  local ci="$1" i key total done_n=0
  total=${_DASH_CAT_LEN[$ci]}
  if [[ "${_DASH_CAT_KIND[$ci]}" == "sol" ]]; then
    _DASH_CNT_TEXT="$total"; _DASH_CNT_COLOR="$_DC_DIM"
    return 0
  fi
  for (( i = _DASH_CAT_FIRST[ci]; i < _DASH_CAT_FIRST[ci] + total; i++ )); do
    key="${_DASH_KEYS_ALL[$i]}"
    _dash_item_status "$key"
    [[ "$_DASH_ST_CODE" == "applied" || "$_DASH_ST_CODE" == "running" ]] && done_n=$(( done_n + 1 ))
  done
  _DASH_CNT_TEXT="${done_n}/${total}"
  if (( total > 0 && done_n == total )); then _DASH_CNT_COLOR="$_DC_OK"; else _DASH_CNT_COLOR="$_DC_DIM"; fi
}

# 已选条目（按显示顺序）
_dash_selected_keys() {
  local key
  for key in "${_DASH_KEYS_ALL[@]}"; do
    [[ -n "${_DASH_SEL[$key]:-}" ]] && printf '%s\n' "$key"
  done
  return 0
}

# 已选条目签名（按显示顺序、每个键后跟一个空格，与预演签名 _DASH_PLAN_SIG 比较）写入 _DASH_SIG
# 替代 $(_dash_selected_keys | tr '\n' ' ')：每帧省去一个子 shell 与一个 tr 进程
_dash_sel_sig() {
  local key
  _DASH_SIG=""
  for key in "${_DASH_KEYS_ALL[@]}"; do
    [[ -n "${_DASH_SEL[$key]:-}" ]] && _DASH_SIG+="${key} "
  done
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 绘制辅助（结果写入 _DASH_L，宽度精确）
# ═══════════════════════════════════════════════════════════════

# 盒子顶边：╭─ 标题 ───── 右侧 ─╮
_dash_box_top() {
  local width="$1" title="$2" right="${3:-}" tw rw fill line
  ui_str_fit "$title" $(( width > 8 ? width - 8 : 1 )); title="${_UI_FIT%"${_UI_FIT##*[! ]}"}"
  ui_str_width "$title"; tw=$_UI_W
  rw=0
  if [[ -n "$right" ]]; then
    ui_str_width "$right"; rw=$(( _UI_W + 3 ))
    if (( tw + rw + 6 > width )); then
      # 右侧文字过长：截断到剩余宽度；剩余不足 8 列时整段省略
      local avail=$(( width - tw - 9 ))
      if (( avail >= 8 )); then
        ui_str_fit "$right" "$avail"; right="${_UI_FIT%"${_UI_FIT##*[! ]}"}"
        ui_str_width "$right"; rw=$(( _UI_W + 3 ))
      else
        right=""; rw=0
      fi
    fi
  fi
  fill=$(( width - 5 - tw - rw ))
  (( fill < 0 )) && fill=0
  ui_str_repeat "─" "$fill"; line="$_UI_FIT"
  if [[ -n "$right" ]]; then
    _DASH_L="${_DC_BORDER}╭─ ${_DC_RESET}${_DC_ACC}${title}${_DC_RESET}${_DC_BORDER} ${line} ${_DC_RESET}${_DC_DIM}${right}${_DC_RESET}${_DC_BORDER} ─╮${_DC_RESET}"
  else
    _DASH_L="${_DC_BORDER}╭─ ${_DC_RESET}${_DC_ACC}${title}${_DC_RESET}${_DC_BORDER} ${line}╮${_DC_RESET}"
  fi
}

# 盒子底边
_dash_box_bottom() {
  ui_str_repeat "─" $(( $1 - 2 ))
  _DASH_L="${_DC_BORDER}╰${_UI_FIT}╯${_DC_RESET}"
}

# 盒子内容行：│ 内容 │（内容已是精确宽度 width-4 的着色串）；$3=1 时整行高亮
_dash_box_row() {
  local content="$2" sel="${3:-0}"
  if [[ "$sel" == "1" ]]; then
    # 焦点行去掉灰色前景：灰字在蓝底上对比度低，且部分终端/渲染器对"亮黑前景+背景"单独着色，
    # 使高亮在列间断开；每个 reset 后重新打开背景，保证整行背景连续
    [[ -n "$_DC_DIM" ]] && content="${content//"$_DC_DIM"/}"
    content="${_DC_SEL}${content//"$_DC_RESET"/"${_DC_RESET}${_DC_SEL}"}${_DC_RESET}"
    _DASH_L="${_DC_BORDER}│${_DC_RESET}${_DC_SEL} ${content}${_DC_SEL} ${_DC_RESET}${_DC_BORDER}│${_DC_RESET}"
  else
    _DASH_L="${_DC_BORDER}│${_DC_RESET} ${content} ${_DC_BORDER}│${_DC_RESET}"
  fi
}

# 空白内容（宽度 n）
_dash_blank() { printf -v _UI_FIT '%*s' "$1" ''; }

# 条形仪表：设置 _DASH_G（宽度 = $2）
_dash_gauge() {
  local pct="$1" width="$2" filled color bar rest
  if (( pct < 0 )); then
    ui_str_repeat "░" "$width"
    _DASH_G="${_DC_DIM}${_UI_FIT}${_DC_RESET}"
    return 0
  fi
  filled=$(( (pct * width + 50) / 100 ))
  (( pct > 0 && filled == 0 )) && filled=1
  (( filled > width )) && filled=$width
  if (( pct >= 90 )); then color="$_DC_BAD"; elif (( pct >= 70 )); then color="$_DC_WARN"; else color="$_DC_OK"; fi
  ui_str_repeat "█" "$filled"; bar="$_UI_FIT"
  ui_str_repeat "░" $(( width - filled )); rest="$_UI_FIT"
  _DASH_G="${color}${bar}${_DC_RESET}${_DC_DIM}${rest}${_DC_RESET}"
}

# 百分比文本（宽度 4，右对齐）
_dash_pct() {
  if (( $1 < 0 )); then _DASH_P="   …"; else printf -v _DASH_P '%3d%%' "$1"; fi
}

# ═══════════════════════════════════════════════════════════════
# 布局
# ═══════════════════════════════════════════════════════════════

# 检测终端尺寸并确定布局模式
_dash_layout() {
  local c l
  c=$(tput cols 2>/dev/null) || c=""
  l=$(tput lines 2>/dev/null) || l=""
  [[ "$c" =~ ^[0-9]+$ ]] || c="${COLUMNS:-80}"
  [[ "$l" =~ ^[0-9]+$ ]] || l="${LINES:-24}"
  _dash_layout_set "$c" "$l"
}

# 按给定尺寸设置布局（拆出便于测试）
_dash_layout_set() {
  _DASH_COLS="$1" _DASH_ROWS="$2"
  # 最后一列留空：避免写满整行触发自动换行；也给 Ambiguous 宽度字符留余量
  _DASH_W=$(( _DASH_COLS - 1 ))
  if (( _DASH_COLS < DASH_MIN_COLS || _DASH_ROWS < DASH_MIN_ROWS )); then
    _DASH_MODE="tiny"
  elif (( _DASH_COLS < DASH_MIN_WIDE_COLS || _DASH_ROWS < DASH_MIN_WIDE_ROWS )); then
    _DASH_MODE="narrow"
  else
    _DASH_MODE="wide"
  fi
}

# ═══════════════════════════════════════════════════════════════
# 合成各区域
# ═══════════════════════════════════════════════════════════════

# 系统信息框（3 行）
_dash_compose_info() {
  local w=$_DASH_W inner=$(( _DASH_W - 4 ))
  local right="${_SI_OS} · ${_SI_ARCH} · ${_SI_HOST} · ${_SI_IP}"
  _dash_box_top "$w" "DebNAS ${DEBNAS_VERSION:-v3}" "$right"
  _DASH_FRAME+=("$_DASH_L")

  local up="运行 ${_SI_UPTIME:-…}" upd_val="${_SI_UPDATES:-…}" upd_color="$_DC_DIM"
  [[ "$upd_val" =~ ^[0-9]+$ ]] && { if (( upd_val > 0 )); then upd_color="$_DC_WARN"; else upd_color="$_DC_OK"; fi; }
  ui_str_width "$up"; local upw=$_UI_W
  ui_str_width "待更新 ${upd_val}"; local updw=$_UI_W
  # 固定部分：标签(4+5+7) + 百分比(3×4) + 仪表后空格(3) + 间隔(4×3) + 运行/待更新
  local fixed=$(( 16 + 12 + 3 + 12 + upw + updw ))
  local g=$(( (inner - fixed) / 3 ))
  (( g > 14 )) && g=14
  local content="" used=0
  if (( g >= 4 )); then
    _dash_gauge "$_SI_CPU" "$g"; _dash_pct "$_SI_CPU"
    content+="${_DC_DIM}CPU${_DC_RESET} ${_DASH_G} ${_DASH_P}   "
    _dash_gauge "$_SI_MEM" "$g"; _dash_pct "$_SI_MEM"
    content+="${_DC_DIM}内存${_DC_RESET} ${_DASH_G} ${_DASH_P}   "
    _dash_gauge "$_SI_DISK" "$g"; _dash_pct "$_SI_DISK"
    content+="${_DC_DIM}根分区${_DC_RESET} ${_DASH_G} ${_DASH_P}   "
    used=$(( 16 + 12 + 3 + 9 + g * 3 ))
  else
    _dash_pct "$_SI_CPU"; local p1="$_DASH_P"; _dash_pct "$_SI_MEM"; local p2="$_DASH_P"; _dash_pct "$_SI_DISK"
    content+="${_DC_DIM}CPU${_DC_RESET}${p1}  ${_DC_DIM}内存${_DC_RESET}${p2}  ${_DC_DIM}根${_DC_RESET}${_DASH_P}  "
    used=$(( 3 + 4 + 2 + 4 + 4 + 2 + 2 + 4 + 2 ))
  fi
  content+="${_DC_DIM}运行${_DC_RESET} ${_SI_UPTIME:-…}   ${_DC_DIM}待更新${_DC_RESET} ${upd_color}${upd_val}${_DC_RESET}"
  used=$(( used + upw + 3 + updw ))
  if (( used <= inner )); then
    _dash_blank $(( inner - used )); content+="$_UI_FIT"
  else
    # 极端情况：回退为纯文本截断，保证边框对齐
    ui_str_fit "CPU ${_SI_CPU}% 内存 ${_SI_MEM}% 根分区 ${_SI_DISK}% ${up} 待更新 ${upd_val}" "$inner"
    content="$_UI_FIT"
  fi
  _dash_box_row "$w" "$content"
  _DASH_FRAME+=("$_DASH_L")
  _dash_box_bottom "$w"
  _DASH_FRAME+=("$_DASH_L")
}

# 分类行内容（宽度 inner）：设置 _DASH_C；$2=是否当前分类
_dash_cat_line() {
  local ci="$1" inner="$2" name marker
  name="${_DASH_CAT_NAME[$ci]}"
  _dash_cat_count "$ci"
  local cw=5
  if (( ci == _DASH_CAT && _DASH_SEARCH_MODE == 0 )); then marker="${_DC_ACC}▶${_DC_RESET} "; else marker="  "; fi
  ui_str_fit "$name" $(( inner - 2 - cw - 1 ))
  local n="$_UI_FIT"
  ui_str_fit "$_DASH_CNT_TEXT" "$cw" right
  _DASH_C="${marker}${n} ${_DASH_CNT_COLOR}${_UI_FIT}${_DC_RESET}"
}

# 搜索行内容（宽度 inner）：设置 _DASH_C
_dash_search_line() {
  local inner="$1"
  if (( _DASH_SEARCH_MODE == 1 )); then
    ui_str_fit "/ ${_DASH_QUERY}▏" "$inner"
    _DASH_C="${_DC_ACC}${_UI_FIT}${_DC_RESET}"
  elif (( _DASH_SEARCH_MODE == 2 )); then
    ui_str_fit "/ ${_DASH_QUERY}（${#_DASH_LIST[@]} 项）" "$inner"
    _DASH_C="${_DC_ACC}${_UI_FIT}${_DC_RESET}"
  else
    ui_str_fit "/ 搜索功能…" "$inner"
    _DASH_C="${_DC_DIM}${_UI_FIT}${_DC_RESET}"
  fi
}

# 右栏列宽：设置 _DASH_CW_NAME / _DASH_CW_ST / _DASH_CW_DESC
_dash_item_cols() {
  local inner="$1"
  _DASH_CW_ST=10
  _DASH_CW_NAME=$(( inner * 26 / 100 ))
  (( _DASH_CW_NAME < 12 )) && _DASH_CW_NAME=12
  (( _DASH_CW_NAME > 24 )) && _DASH_CW_NAME=24
  _DASH_CW_DESC=$(( inner - 4 - _DASH_CW_NAME - 2 - _DASH_CW_ST - 2 ))
  if (( _DASH_CW_DESC < 0 )); then _DASH_CW_DESC=0; fi
  return 0
}

# 条目行内容（宽度 inner）：设置 _DASH_C
_dash_item_line() {
  local key="$1" inner="$2" ck
  _dash_item_cols "$inner"
  if [[ -n "${_DASH_SEL[$key]:-}" ]]; then ck="${_DC_ACC}[✓]${_DC_RESET} "; else ck="${_DC_DIM}[ ]${_DC_RESET} "; fi
  ui_str_fit "${_DASH_ITEM_NAME[$key]}" "$_DASH_CW_NAME"
  local name="$_UI_FIT"
  _dash_item_status "$key"
  local mod=""
  [[ "$key" == m:* ]] && mod="${key#m:}"
  _dash_status_view "$_DASH_ST_CODE" "$_DASH_ST_DESC" "$mod"
  ui_str_fit "$_DASH_SV_TEXT" "$_DASH_CW_ST"
  local st="${_DASH_SV_COLOR}${_UI_FIT}${_DC_RESET}"
  local desc="$_DASH_ST_DESC" dcolor="$_DC_DIM"
  if [[ "$_DASH_ST_CODE" == "unknown" || "$_DASH_ST_CODE" == "pending" ]] && [[ -n "${_DASH_ITEM_DESC[$key]}" ]]; then
    desc="${_DASH_ITEM_DESC[$key]}"
  fi
  case "$_DASH_ST_CODE" in warn|partial) dcolor="$_DC_WARN" ;; error) dcolor="$_DC_BAD" ;; esac
  ui_str_fit "$desc" "$_DASH_CW_DESC"
  _DASH_C="${ck}${name}  ${st}  ${dcolor}${_UI_FIT}${_DC_RESET}"
}

# 表头行（宽度 inner）
_dash_item_header() {
  local inner="$1"
  _dash_item_cols "$inner"
  ui_str_fit "功能" "$_DASH_CW_NAME"; local a="$_UI_FIT"
  ui_str_fit "状态" "$_DASH_CW_ST"; local b="$_UI_FIT"
  ui_str_fit "说明" "$_DASH_CW_DESC"
  _DASH_C="${_DC_DIM}    ${a}  ${b}  ${_UI_FIT}${_DC_RESET}"
}

# 详情行（2 行，宽度 inner）：设置 _DASH_D1 / _DASH_D2
_dash_detail_lines() {
  local inner="$1" key
  if [[ ${#_DASH_LIST[@]} -eq 0 ]]; then
    if (( _DASH_SEARCH_MODE > 0 )); then ui_str_fit "没有匹配「${_DASH_QUERY}」的功能" "$inner"; else ui_str_fit "此分类没有功能" "$inner"; fi
    _DASH_D1="${_DC_DIM}${_UI_FIT}${_DC_RESET}"
    _dash_blank "$inner"; _DASH_D2="$_UI_FIT"
    return 0
  fi
  key="${_DASH_LIST[$_DASH_FOCUS]}"
  local name="${_DASH_ITEM_NAME[$key]}" desc="${_DASH_ITEM_DESC[$key]:-}"
  ui_str_width "▸ ${name} — "; local hw=$_UI_W
  if (( hw + 4 <= inner )); then
    ui_str_fit "$name" $(( hw - 5 )); local nm="$_UI_FIT"
    ui_str_fit "${desc:-（无说明）}" $(( inner - hw ))
    _DASH_D1="${_DC_ACC}▸ ${_DC_RESET}${_DC_OK}${nm}${_DC_RESET} — ${_UI_FIT}"
  else
    ui_str_fit "▸ ${name}" "$inner"
    _DASH_D1="${_DC_OK}${_UI_FIT}${_DC_RESET}"
  fi
  local extra=""
  _dash_item_status "$key"
  if [[ "$key" == m:* ]]; then
    local m="${key#m:}" dep="" inter=""
    extra="状态：${_DASH_ST_DESC}"
    get_module_field_var dep "$m" "depend_modules" || dep=""
    get_module_field_var inter "$m" "interactive" "false" || inter="false"
    [[ -n "$dep" ]] && extra+=" · 依赖模块：${dep}"
    [[ "$inter" == "true" ]] && extra+=" · 交互式（执行时进入模块菜单）"
    extra+=" · ${m}"
  else
    extra="状态：${_DASH_ST_DESC}"
  fi
  ui_str_fit "  ${extra}" "$inner"
  _DASH_D2="${_DC_DIM}${_UI_FIT}${_DC_RESET}"
}

# 确保焦点/分类在可见窗口内
_dash_clamp_scroll() {
  local win="$1" n=${#_DASH_LIST[@]}
  (( win < 1 )) && win=1
  (( _DASH_FOCUS < _DASH_SCROLL )) && _DASH_SCROLL=$_DASH_FOCUS
  (( _DASH_FOCUS >= _DASH_SCROLL + win )) && _DASH_SCROLL=$(( _DASH_FOCUS - win + 1 ))
  (( _DASH_SCROLL > n - win )) && _DASH_SCROLL=$(( n - win ))
  (( _DASH_SCROLL < 0 )) && _DASH_SCROLL=0
  return 0
}
_dash_clamp_cscroll() {
  local win="$1" n=${#_DASH_CAT_NAME[@]}
  (( win < 1 )) && win=1
  (( _DASH_CAT < _DASH_CSCROLL )) && _DASH_CSCROLL=$_DASH_CAT
  (( _DASH_CAT >= _DASH_CSCROLL + win )) && _DASH_CSCROLL=$(( _DASH_CAT - win + 1 ))
  (( _DASH_CSCROLL > n - win )) && _DASH_CSCROLL=$(( n - win ))
  (( _DASH_CSCROLL < 0 )) && _DASH_CSCROLL=0
  return 0
}

# 右栏标题
_dash_right_title() {
  if (( _DASH_SEARCH_MODE > 0 )); then
    _DASH_T="搜索：${_DASH_QUERY}"
  else
    _DASH_T="${_DASH_CAT_NAME[$_DASH_CAT]}"
  fi
}

# 预演框内容行（数组 _DASH_PLAN_VIEW，每元素宽度 inner）
_dash_plan_view() {
  local inner="$1" max="$2"
  _DASH_PLAN_VIEW=()
  local nsel=${#_DASH_SEL[@]}
  _dash_sel_sig
  local sig="$_DASH_SIG"
  if (( nsel == 0 )); then
    ui_str_fit "未勾选任何功能：空格 勾选，d 生成预演；直接回车执行当前项。" "$inner"
    _DASH_PLAN_VIEW+=("${_DC_DIM}${_UI_FIT}${_DC_RESET}")
  elif [[ "$sig" != "$_DASH_PLAN_SIG" ]]; then
    local names="" k
    for k in "${_DASH_KEYS_ALL[@]}"; do
      [[ -n "${_DASH_SEL[$k]:-}" ]] && names+="${names:+、}${_DASH_ITEM_NAME[$k]}"
    done
    ui_str_fit "已选 ${nsel} 项：${names}" "$inner"
    _DASH_PLAN_VIEW+=("$_UI_FIT")
    ui_str_fit "按 d 生成预演（只读检测将安装的包、修改的文件与风险），回车执行" "$inner"
    _DASH_PLAN_VIEW+=("${_DC_DIM}${_UI_FIT}${_DC_RESET}")
  else
    local total=${#_DASH_PLAN[@]} i shown line
    local -a view=()
    if (( total <= max )); then
      view=("${_DASH_PLAN[@]}")
      shown=$total
    else
      # 放不下时优先保留风险行（风险最重要），其余按顺序截取
      local -a risks=() others=()
      for line in "${_DASH_PLAN[@]}"; do
        if [[ "$line" == risk\|* ]]; then risks+=("$line"); else others+=("$line"); fi
      done
      shown=$(( max - 1 ))
      local nr=${#risks[@]}
      (( nr > shown )) && nr=$shown
      view=("${others[@]:0:shown - nr}" "${risks[@]:0:nr}")
    fi
    for line in "${view[@]}"; do
      [[ -n "$line" ]] || continue
      _dash_plan_line "$line" "$inner"
      _DASH_PLAN_VIEW+=("$_DASH_C")
    done
    if (( total > max )); then
      ui_str_fit "… 另有 $(( total - shown )) 条，回车后的确认页显示完整预演" "$inner"
      _DASH_PLAN_VIEW+=("${_DC_DIM}${_UI_FIT}${_DC_RESET}")
    fi
  fi
  while (( ${#_DASH_PLAN_VIEW[@]} < max )); do
    _dash_blank "$inner"; _DASH_PLAN_VIEW+=("$_UI_FIT")
  done
}

# 预演类型 → 标签与颜色：设置 _DASH_PT / _DASH_PC
_dash_plan_label() {
  case "$1" in
    pkg)     _DASH_PT="+ 安装"; _DASH_PC="$_DC_OK" ;;
    write)   _DASH_PT="~ 修改"; _DASH_PC="$_DC_WARN" ;;
    service) _DASH_PT="* 服务"; _DASH_PC="$_DC_ACC" ;;
    port)    _DASH_PT="# 端口"; _DASH_PC="$_DC_ACC" ;;
    cron)    _DASH_PT="@ 定时"; _DASH_PC="$_DC_ACC" ;;
    user)    _DASH_PT="& 用户"; _DASH_PC="$_DC_WARN" ;;
    risk)    _DASH_PT="! 风险"; _DASH_PC="$_DC_BAD" ;;
    *)       _DASH_PT="· 说明"; _DASH_PC="$_DC_DIM" ;;
  esac
}

# 单条预演行（"type|target|note"）→ _DASH_C（宽度 inner）
_dash_plan_line() {
  local line="$1" inner="$2" type target note rest
  type="${line%%|*}"; rest="${line#*|}"; target="${rest%%|*}"; note="${rest#*|}"
  [[ "$rest" == *"|"* ]] || note=""
  _dash_plan_label "$type"
  local tw=$(( inner * 42 / 100 ))
  (( tw > 46 )) && tw=46
  (( tw < 10 )) && tw=10
  local nw=$(( inner - 6 - 2 - tw - 2 ))
  if [[ "$type" == "risk" || "$type" == "info" ]] && [[ -n "$note" ]]; then
    # 风险/说明：目标 + 备注连成一句，更易读
    ui_str_fit "${target}：${note}" $(( inner - 8 ))
    _DASH_C="${_DASH_PC}${_DASH_PT}${_DC_RESET}  ${_UI_FIT}"
    return 0
  fi
  ui_str_fit "$target" "$tw"; local t="$_UI_FIT"
  if (( nw > 0 )); then ui_str_fit "$note" "$nw"; else _UI_FIT=""; fi
  _DASH_C="${_DASH_PC}${_DASH_PT}${_DC_RESET}  ${t}  ${_DC_DIM}${_UI_FIT}${_DC_RESET}"
}

# 快捷键行：设置 _DASH_L（宽度 _DASH_W）
_dash_compose_footer() {
  local w=$_DASH_W
  if [[ -n "$_DASH_MSG" ]]; then
    ui_str_fit " ${_DASH_MSG}" "$w"
    _DASH_L="${_DC_ACC}${_UI_FIT}${_DC_RESET}"
    return 0
  fi
  local -a pairs
  if (( _DASH_SEARCH_MODE == 1 )); then
    pairs=("输入" "过滤" "↑↓" "移动" "回车" "确认" "Esc" "取消")
  elif [[ "$_DASH_MODE" == "narrow" ]]; then
    pairs=("↑↓" "移动" "→←" "进入/返回" "空格" "勾选" "回车" "执行" "d" "预演" "/" "搜索" "?" "帮助" "q" "退出" "l" "日志")
  else
    pairs=("↑↓" "移动" "←→" "切换栏" "空格" "勾选" "回车" "执行" "d" "预演" "/" "搜索" "l" "日志" "?" "帮助" "q" "退出")
  fi
  local out=" " used=1 i k lab kw lw gap=2 total=1 sp
  # 先按 2 空格间隔试算，放不下时收紧为 1 空格，仍放不下再从末尾丢弃
  for (( i = 0; i < ${#pairs[@]}; i += 2 )); do
    ui_str_width "${pairs[i]}${pairs[i+1]}"; total=$(( total + _UI_W + 5 ))
  done
  (( total > w )) && gap=1
  printf -v sp "%*s" "$gap" ""
  for (( i = 0; i < ${#pairs[@]}; i += 2 )); do
    k="${pairs[i]}" lab="${pairs[i+1]}"
    ui_str_width "$k"; kw=$(( _UI_W + 2 ))
    ui_str_width "$lab"; lw=$_UI_W
    (( used + kw + 1 + lw + gap > w )) && break
    if [[ -n "$_DC_KEY" ]]; then
      out+="${_DC_KEY} ${k} ${_DC_RESET} ${_DC_DIM}${lab}${_DC_RESET}${sp}"
    else
      out+="[${k}] ${lab}${sp}"
    fi
    used=$(( used + kw + 1 + lw + gap ))
  done
  _dash_blank $(( w - used ))
  _DASH_L="${out}${_UI_FIT}"
}

# 覆盖层（帮助/日志）：追加 height 行（框线含在内）
_dash_compose_overlay() {
  local height="$1" w=$_DASH_W inner=$(( _DASH_W - 4 )) title right
  case "$_DASH_OVERLAY" in
    help) title="帮助"; right="任意键返回" ;;
    log)  title="日志 · ${_DASH_OVERLAY_TITLE:-}"; right="↑↓ 滚动 · 其他键返回" ;;
  esac
  _dash_box_top "$w" "$title" "$right"; _DASH_FRAME+=("$_DASH_L")
  local body=$(( height - 2 )) i n=${#_DASH_OVERLAY_LINES[@]}
  (( _DASH_OVERLAY_OFF > n - body )) && _DASH_OVERLAY_OFF=$(( n - body ))
  (( _DASH_OVERLAY_OFF < 0 )) && _DASH_OVERLAY_OFF=0
  for (( i = 0; i < body; i++ )); do
    ui_str_fit "${_DASH_OVERLAY_LINES[_DASH_OVERLAY_OFF + i]:-}" "$inner"
    _dash_box_row "$w" "$_UI_FIT"; _DASH_FRAME+=("$_DASH_L")
  done
  _dash_box_bottom "$w"; _DASH_FRAME+=("$_DASH_L")
}

# ═══════════════════════════════════════════════════════════════
# 整帧合成
# ═══════════════════════════════════════════════════════════════

# 宽屏双栏布局
_dash_compose_wide() {
  local rows=$_DASH_ROWS w=$_DASH_W
  _dash_compose_info

  local P=4
  (( rows >= 32 )) && P=5
  (( rows >= 36 )) && P=6
  local ncat=${#_DASH_CAT_NAME[@]} maxitems=0 i
  for (( i = 0; i < ncat; i++ )); do (( _DASH_CAT_LEN[i] > maxitems )) && maxitems=${_DASH_CAT_LEN[i]}; done
  (( _DASH_SEARCH_MODE > 0 && ${#_DASH_LIST[@]} > maxitems )) && maxitems=${#_DASH_LIST[@]}
  local need=$(( ncat + 2 ))
  (( maxitems + 4 > need )) && need=$(( maxitems + 4 ))
  local maxph=$(( rows - 3 - (P + 2) - 1 ))
  local PH=$(( need + 2 ))
  (( PH > maxph )) && PH=$maxph
  # 预演已生成且条目较多时，用剩余行扩展预演框（保留 1 行空白 + 快捷键行）
  if (( ${#_DASH_SEL[@]} > 0 && ${#_DASH_PLAN[@]} > P )) && _dash_sel_sig && [[ "$_DASH_SIG" == "$_DASH_PLAN_SIG" ]]; then
    local pmax=$(( rows - 3 - PH - 2 - 2 ))
    P=${#_DASH_PLAN[@]}
    (( P > pmax )) && P=$pmax
  fi

  if [[ -n "$_DASH_OVERLAY" ]]; then
    _dash_compose_overlay $(( rows - 3 - 1 ))
    _dash_compose_footer; _DASH_FRAME+=("$_DASH_L")
    return 0
  fi

  local LW=24
  (( _DASH_COLS >= 120 )) && LW=26
  local RW=$(( w - LW - 1 ))
  local LI=$(( LW - 4 )) RI=$(( RW - 4 ))
  local C=$(( PH - 2 ))

  # 左栏
  local -a left=()
  _dash_box_top "$LW" "分类"; left+=("$_DASH_L")
  local cwin=$(( C - 2 ))
  _dash_clamp_cscroll "$cwin"
  local r ci
  for (( r = 0; r < C; r++ )); do
    if (( r == C - 1 )); then
      _dash_search_line "$LI"
      _dash_box_row "$LW" "$_DASH_C" $(( _DASH_SEARCH_MODE > 0 && _DASH_PANE == 0 ? 1 : 0 ))
    elif (( r < cwin )) && (( _DASH_CSCROLL + r < ncat )); then
      ci=$(( _DASH_CSCROLL + r ))
      _dash_cat_line "$ci" "$LI"
      _dash_box_row "$LW" "$_DASH_C" $(( ci == _DASH_CAT && _DASH_PANE == 0 && _DASH_SEARCH_MODE == 0 ? 1 : 0 ))
    else
      _dash_blank "$LI"; _dash_box_row "$LW" "$_UI_FIT"
    fi
    left+=("$_DASH_L")
  done
  _dash_box_bottom "$LW"; left+=("$_DASH_L")

  # 右栏
  local -a right=()
  local nsel=${#_DASH_SEL[@]}
  _dash_right_title
  _dash_box_top "$RW" "$_DASH_T" "已选 ${nsel} 项"; right+=("$_DASH_L")
  local win=$(( C - 4 )) n=${#_DASH_LIST[@]}
  _dash_clamp_scroll "$win"
  local vis=$(( n - _DASH_SCROLL )); (( vis > win )) && vis=$win; (( vis < 0 )) && vis=0
  _dash_detail_lines "$RI"
  local sep_row=$(( 1 + vis )) idx
  for (( r = 0; r < C; r++ )); do
    if (( r == 0 )); then
      _dash_item_header "$RI"; _dash_box_row "$RW" "$_DASH_C"
    elif (( r <= vis )); then
      idx=$(( _DASH_SCROLL + r - 1 ))
      _dash_item_line "${_DASH_LIST[$idx]}" "$RI"
      _dash_box_row "$RW" "$_DASH_C" $(( idx == _DASH_FOCUS && _DASH_PANE == 1 ? 1 : 0 ))
    elif (( r == sep_row )); then
      local more=""
      (( _DASH_SCROLL > 0 )) && more+="↑"
      (( _DASH_SCROLL + vis < n )) && more+="↓"
      ui_str_repeat "┄" $(( RI - ${#more} - (${#more} > 0 ? 1 : 0) ))
      if [[ -n "$more" ]]; then _UI_FIT="${_UI_FIT} ${more}"; fi
      _dash_box_row "$RW" "${_DC_BORDER}${_UI_FIT}${_DC_RESET}"
    elif (( r == sep_row + 1 )); then
      _dash_box_row "$RW" "$_DASH_D1"
    elif (( r == sep_row + 2 )); then
      _dash_box_row "$RW" "$_DASH_D2"
    else
      _dash_blank "$RI"; _dash_box_row "$RW" "$_UI_FIT"
    fi
    right+=("$_DASH_L")
  done
  _dash_box_bottom "$RW"; right+=("$_DASH_L")

  for (( r = 0; r < PH; r++ )); do
    _DASH_FRAME+=("${left[r]} ${right[r]}")
  done

  # 预演框
  _dash_plan_view $(( w - 4 )) "$P"
  _dash_box_top "$w" "执行计划 · 预演" "d 预演 / 回车 执行"; _DASH_FRAME+=("$_DASH_L")
  for (( r = 0; r < P; r++ )); do
    _dash_box_row "$w" "${_DASH_PLAN_VIEW[r]}"; _DASH_FRAME+=("$_DASH_L")
  done
  _dash_box_bottom "$w"; _DASH_FRAME+=("$_DASH_L")

  (( ${#_DASH_FRAME[@]} < rows - 1 )) && _DASH_FRAME+=("")
  _dash_compose_footer; _DASH_FRAME+=("$_DASH_L")
}

# 窄屏单栏布局（两级：分类 → 功能）
_dash_compose_narrow() {
  local rows=$_DASH_ROWS w=$_DASH_W inner=$(( _DASH_W - 4 ))
  _dash_pct "$_SI_CPU"; local p1="${_DASH_P// /}"
  _dash_pct "$_SI_MEM"; local p2="${_DASH_P// /}"
  _dash_pct "$_SI_DISK"; local p3="${_DASH_P// /}"
  ui_str_fit " DebNAS ${DEBNAS_VERSION:-v3} · ${_SI_HOST} · CPU ${p1} 内存 ${p2} 根 ${p3} · 待更新 ${_SI_UPDATES:-…}" "$w"
  _DASH_FRAME+=("${_DC_ACC}${_UI_FIT}${_DC_RESET}")

  local P=0
  (( rows >= 20 )) && P=3
  local boxh=$(( rows - 1 - 1 - (P > 0 ? P + 2 : 0) ))

  if [[ -n "$_DASH_OVERLAY" ]]; then
    _dash_compose_overlay $(( rows - 2 ))
    _dash_compose_footer; _DASH_FRAME+=("$_DASH_L")
    return 0
  fi

  local C=$(( boxh - 2 )) r
  local nsel=${#_DASH_SEL[@]}
  if (( _DASH_PANE == 0 )); then
    local ncat=${#_DASH_CAT_NAME[@]} ci
    _dash_box_top "$w" "分类" "已选 ${nsel} 项"; _DASH_FRAME+=("$_DASH_L")
    local cwin=$(( C - 1 ))
    _dash_clamp_cscroll "$cwin"
    for (( r = 0; r < C; r++ )); do
      if (( r == C - 1 )); then
        _dash_search_line "$inner"; _dash_box_row "$w" "$_DASH_C" $(( _DASH_SEARCH_MODE > 0 ? 1 : 0 ))
      elif (( _DASH_CSCROLL + r < ncat )); then
        ci=$(( _DASH_CSCROLL + r ))
        _dash_cat_line "$ci" "$inner"
        _dash_box_row "$w" "$_DASH_C" $(( ci == _DASH_CAT && _DASH_SEARCH_MODE == 0 ? 1 : 0 ))
      else
        _dash_blank "$inner"; _dash_box_row "$w" "$_UI_FIT"
      fi
      _DASH_FRAME+=("$_DASH_L")
    done
  else
    _dash_right_title
    _dash_box_top "$w" "$_DASH_T" "已选 ${nsel} 项"; _DASH_FRAME+=("$_DASH_L")
    local win=$(( C - 3 )) n=${#_DASH_LIST[@]} idx
    _dash_clamp_scroll "$win"
    local vis=$(( n - _DASH_SCROLL )); (( vis > win )) && vis=$win; (( vis < 0 )) && vis=0
    _dash_detail_lines "$inner"
    for (( r = 0; r < C; r++ )); do
      if (( r == 0 )); then
        _dash_item_header "$inner"; _dash_box_row "$w" "$_DASH_C"
      elif (( r <= vis )); then
        idx=$(( _DASH_SCROLL + r - 1 ))
        _dash_item_line "${_DASH_LIST[$idx]}" "$inner"
        _dash_box_row "$w" "$_DASH_C" $(( idx == _DASH_FOCUS ? 1 : 0 ))
      elif (( r == vis + 1 )); then
        ui_str_repeat "┄" "$inner"; _dash_box_row "$w" "${_DC_BORDER}${_UI_FIT}${_DC_RESET}"
      elif (( r == vis + 2 )); then
        _dash_box_row "$w" "$_DASH_D1"
      else
        _dash_blank "$inner"; _dash_box_row "$w" "$_UI_FIT"
      fi
      _DASH_FRAME+=("$_DASH_L")
    done
  fi
  _dash_box_bottom "$w"; _DASH_FRAME+=("$_DASH_L")

  if (( P > 0 )); then
    _dash_plan_view "$inner" "$P"
    _dash_box_top "$w" "执行计划 · 预演" "d / 回车"; _DASH_FRAME+=("$_DASH_L")
    for (( r = 0; r < P; r++ )); do
      _dash_box_row "$w" "${_DASH_PLAN_VIEW[r]}"; _DASH_FRAME+=("$_DASH_L")
    done
    _dash_box_bottom "$w"; _DASH_FRAME+=("$_DASH_L")
  fi
  _dash_compose_footer; _DASH_FRAME+=("$_DASH_L")
}

# 合成整帧到 _DASH_FRAME
ui_dashboard_compose() {
  _DASH_FRAME=()
  _dash_build_list
  case "$_DASH_MODE" in
    wide)   _dash_compose_wide ;;
    narrow) _dash_compose_narrow ;;
    *)
      ui_str_fit "终端太小（当前 ${_DASH_COLS}x${_DASH_ROWS}，至少 ${DASH_MIN_COLS}x${DASH_MIN_ROWS}）" "$_DASH_W"
      _DASH_FRAME+=("$_UI_FIT")
      ui_str_fit "请放大窗口，或按 q 退出（DEBNAS_UI=classic 可使用旧版界面）" "$_DASH_W"
      _DASH_FRAME+=("$_UI_FIT")
      ;;
  esac
  while (( ${#_DASH_FRAME[@]} > _DASH_ROWS )); do unset '_DASH_FRAME[-1]'; done
  return 0
}

# 只重写与上一帧不同的行
_dash_flush() {
  local out="" i
  for (( i = 0; i < _DASH_ROWS; i++ )); do
    if [[ "${_DASH_FRAME[i]-}" != "${_DASH_PREV[i]-__dash_none__}" ]]; then
      out+=$'\e['"$(( i + 1 ))"$';1H\e[0m'"${_DASH_FRAME[i]-}"$'\e[0m\e[K'
    fi
  done
  [[ -n "$out" ]] && printf '%s' "$out"
  _DASH_PREV=("${_DASH_FRAME[@]}")
  # 帧短于屏幕时补齐比较基准
  for (( i = ${#_DASH_FRAME[@]}; i < _DASH_ROWS; i++ )); do _DASH_PREV[i]=""; done
  return 0
}

ui_dashboard_render() {
  ui_dashboard_compose
  _dash_flush
}

# ═══════════════════════════════════════════════════════════════
# 终端控制
# ═══════════════════════════════════════════════════════════════

_dash_tui_enter() {
  _DASH_STTY=$(stty -g 2>/dev/null) || _DASH_STTY=""
  stty -echo -icanon min 1 time 0 2>/dev/null || true
  printf '\e[?1049h\e[?25l\e[H\e[2J'
  _DASH_PREV=()
  _DASH_TUI_ON=1
}

_dash_tui_leave() {
  [[ "$_DASH_TUI_ON" -eq 1 ]] || return 0
  printf '\e[0m\e[?25h\e[?1049l'
  if [[ -n "$_DASH_STTY" ]]; then stty "$_DASH_STTY" 2>/dev/null || true; else stty sane 2>/dev/null || true; fi
  _DASH_TUI_ON=0
}

# EXIT 时恢复终端，并保留原有 EXIT trap（先恢复终端，再以原退出码执行原 trap）
_dash_install_traps() {
  local current existing=""
  current=$(trap -p EXIT 2>/dev/null || true)
  # trap -p 输出形如 trap -- '命令' EXIT（命令内的单引号转义为 '\''）；多行命令同样适用
  if [[ "$current" == "trap -- '"*"' EXIT" ]]; then
    existing="${current#"trap -- '"}"
    existing="${existing%"' EXIT"}"
    existing="${existing//"'\\''"/"'"}"
  fi
  if [[ -n "$existing" && "$existing" != *_dash_tui_leave* ]]; then
    # shellcheck disable=SC2064,SC2154  # 有意在注册时展开 existing；_dash_exit_rc 在 trap 内赋值
    trap "_dash_exit_rc=\$?; _dash_tui_leave; (exit \$_dash_exit_rc); ${existing}" EXIT
  elif [[ -z "$existing" ]]; then
    trap '_dash_tui_leave' EXIT
  fi
  trap '_DASH_QUIT=1' INT
  trap '_DASH_RESIZED=1' WINCH
}

# 读取按键：设置 _DASH_KEY
# 取值：UP DOWN LEFT RIGHT HOME END PGUP PGDN ENTER SPACE TAB BACKSPACE ESC TIMEOUT EOF CHAR:<c>
_dash_read_key() {
  local t="${1:-1}" k="" s="" c rc=0
  IFS= read -rsn1 -t "$t" k || rc=$?
  if (( rc != 0 )); then
    if (( rc > 128 )); then _DASH_KEY="TIMEOUT"; else _DASH_KEY="EOF"; fi
    return 0
  fi
  case "$k" in
    "")          _DASH_KEY="ENTER" ;;
    $'\r'|$'\n') _DASH_KEY="ENTER" ;;
    " ")         _DASH_KEY="SPACE" ;;
    $'\t')       _DASH_KEY="TAB" ;;
    $'\x7f'|$'\b') _DASH_KEY="BACKSPACE" ;;
    $'\e')
      if ! IFS= read -rsn1 -t 0.03 c; then _DASH_KEY="ESC"; return 0; fi
      if [[ "$c" != "[" && "$c" != "O" ]]; then _DASH_KEY="ESC"; return 0; fi
      # 读到终止字节（@ ~ 范围的字母或 ~）为止
      while IFS= read -rsn1 -t 0.03 c; do
        s+="$c"
        [[ "$c" == [A-Za-z~] ]] && break
        (( ${#s} > 6 )) && break
      done
      case "$s" in
        A) _DASH_KEY="UP" ;;    B) _DASH_KEY="DOWN" ;;
        C) _DASH_KEY="RIGHT" ;; D) _DASH_KEY="LEFT" ;;
        H|1~|7~) _DASH_KEY="HOME" ;; F|4~|8~) _DASH_KEY="END" ;;
        5~) _DASH_KEY="PGUP" ;; 6~) _DASH_KEY="PGDN" ;;
        *) _DASH_KEY="OTHER" ;;
      esac
      ;;
    *) _DASH_KEY="CHAR:${k}" ;;
  esac
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 动作
# ═══════════════════════════════════════════════════════════════

_dash_toggle_key() {
  local key="$1"
  if [[ -n "${_DASH_SEL[$key]:-}" ]]; then unset '_DASH_SEL[$key]'; else _DASH_SEL["$key"]=1; fi
}

# 空格：右栏切换当前项；左栏切换整个分类（全选/全不选）
_dash_action_space() {
  if (( _DASH_PANE == 1 )); then
    [[ ${#_DASH_LIST[@]} -gt 0 ]] || return 0
    _dash_toggle_key "${_DASH_LIST[$_DASH_FOCUS]}"
    (( _DASH_FOCUS < ${#_DASH_LIST[@]} - 1 )) && _DASH_FOCUS=$(( _DASH_FOCUS + 1 ))
    return 0
  fi
  (( _DASH_SEARCH_MODE > 0 )) && return 0
  local i all=1 key first=${_DASH_CAT_FIRST[$_DASH_CAT]} len=${_DASH_CAT_LEN[$_DASH_CAT]}
  for (( i = first; i < first + len; i++ )); do
    [[ -n "${_DASH_SEL[${_DASH_KEYS_ALL[$i]}]:-}" ]] || { all=0; break; }
  done
  for (( i = first; i < first + len; i++ )); do
    key="${_DASH_KEYS_ALL[$i]}"
    if (( all )); then unset '_DASH_SEL[$key]'; else _DASH_SEL["$key"]=1; fi
  done
}

# 把条目展开为模块列表（方案按文件顺序展开），去重并按依赖排序
# 参数：条目 key 列表
# 输出：stdout 每行一个模块名
_dash_expand_modules() {
  local IFS=$'\n\t'
  local key m d
  local -a flat=()
  local -A seen=() inlist=() placed=()
  for key in "$@"; do
    if [[ "$key" == s:* ]]; then
      for m in ${_DASH_ITEM_MODS[$key]:-}; do
        [[ -z "${seen[$m]:-}" ]] && { seen["$m"]=1; flat+=("$m"); }
      done
    else
      m="${key#m:}"
      [[ -z "${seen[$m]:-}" ]] && { seen["$m"]=1; flat+=("$m"); }
    fi
  done
  for m in "${flat[@]}"; do inlist["$m"]=1; done
  # 依赖在前：对每个模块，先放入其（同在列表内的）依赖链
  for m in "${flat[@]}"; do
    while IFS= read -r d; do
      [[ -n "$d" && -n "${inlist[$d]:-}" && -z "${placed[$d]:-}" ]] || continue
      placed["$d"]=1
      printf '%s\n' "$d"
    done < <(resolve_module_deps "$m" 2>/dev/null || printf '%s\n' "$m")
    if [[ -z "${placed[$m]:-}" ]]; then placed["$m"]=1; printf '%s\n' "$m"; fi
  done
  return 0
}

# 预演行是否在提示"依赖模块缺失"：risk/info 行中以"<模块名> 模块"或"「<显示名>」"提到依赖模块
# 参数：$1 预演行（type|target|note），$2 依赖模块名
# 返回：0 是，1 否
_dash_plan_mentions_dep() {
  local line="$1" dep="$2" dname="" re
  [[ "$line" == risk\|* || "$line" == info\|* ]] || return 1
  re="(^|[^a-z0-9_-])${dep}[[:space:]]*模块"
  [[ "$line" =~ $re ]] && return 0
  get_module_field_var dname "$dep" "name" || return 1
  [[ "$line" == *"「${dname}」"* ]]
}

# 生成预演：对选中条目展开的模块逐个调用 module_plan，合并为 _DASH_PLAN
# 参数：条目 key 列表（为空时取已选）
# 说明：
#   - 探测时导出 DEBNAS_PLAN_WITH=<本次执行的模块列表，空格分隔，依赖在前>，模块可据此自行判断依赖是否会先执行
#   - 依赖模块也在本次列表中（排在前面）时，模块 plan 里提示该依赖缺失的 risk/info 行
#     （见 _dash_plan_mentions_dep）合并为一条 info"将先执行「依赖」"
#   - 依赖模块未完成且未一起勾选时追加一条 risk
_dash_build_plan() {
  local -a keys=("$@")
  [[ ${#keys[@]} -gt 0 ]] || mapfile -t keys < <(_dash_selected_keys)
  _DASH_PLAN=() _DASH_PLAN_RISKS=0
  local -a mods pkgs=() others=() risks=() deps=() parr=() ahead=()
  mapfile -t mods < <(_dash_expand_modules "${keys[@]}")
  local -A pkg_seen=() mod_set=() done_before=() folded=()
  local m mname line type rest target note p dep plan_with=""
  for m in "${mods[@]}"; do
    [[ -n "$m" ]] || continue
    mod_set["$m"]=1
    plan_with+="${plan_with:+ }${m}"
  done
  for m in "${mods[@]}"; do
    [[ -n "$m" ]] || continue
    mname="${_DASH_ITEM_NAME[m:$m]:-$m}"
    ahead=() folded=()
    get_module_field_var dep "$m" "depend_modules" || dep=""
    if [[ -n "$dep" ]]; then
      IFS=' ,' read -ra deps <<< "$dep"
      for p in "${deps[@]}"; do
        [[ -n "$p" ]] || continue
        if [[ -n "${done_before[$p]:-}" ]]; then
          ahead+=("$p")
        elif [[ -z "${mod_set[$p]:-}" ]] && ! state_is_installed "$p" 2>/dev/null; then
          risks+=("risk|${mname}|依赖模块 ${p} 尚未完成且未勾选，执行时会被 preflight 拦截")
        fi
      done
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      for p in "${ahead[@]+"${ahead[@]}"}"; do
        _dash_plan_mentions_dep "$line" "$p" || continue
        if [[ -z "${folded[$p]:-}" ]]; then
          folded["$p"]=1
          others+=("info|${mname}|将先执行依赖「${_DASH_ITEM_NAME[m:$p]:-$p}」（${p}）")
        fi
        continue 2
      done
      type="${line%%|*}"; rest="${line#*|}"; target="${rest%%|*}"; note="${rest#*|}"
      case "$type" in
        pkg)
          IFS=' ,' read -ra parr <<< "$target"
          for p in "${parr[@]}"; do
            [[ -n "$p" && -z "${pkg_seen[$p]:-}" ]] && { pkg_seen["$p"]=1; pkgs+=("$p"); }
          done
          ;;
        risk) risks+=("$line") ;;
        info)
          # 回退说明（未提供预演）带上模块名，便于识别
          if [[ "$target" == "$m" ]]; then others+=("info|${mname}|${note}"); else others+=("$line"); fi
          ;;
        *) others+=("$line") ;;
      esac
    done < <(DEBNAS_PLAN_WITH="$plan_with" module_probe "$m" plan 2>/dev/null)
    done_before["$m"]=1
  done
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    local pkg_list
    printf -v pkg_list '%s ' "${pkgs[@]}"
    _DASH_PLAN+=("pkg|${pkg_list% }|apt · ${#pkgs[@]} 个包")
  fi
  _DASH_PLAN+=("${others[@]+"${others[@]}"}" "${risks[@]+"${risks[@]}"}")
  _DASH_PLAN_RISKS=${#risks[@]}
  _dash_sel_sig
  _DASH_PLAN_SIG="$_DASH_SIG"
  return 0
}

# 打开帮助覆盖层
_dash_open_help() {
  _DASH_OVERLAY="help" _DASH_OVERLAY_OFF=0
  _DASH_OVERLAY_LINES=(
    "按键"
    "  ↑↓ / j k     移动焦点              ←→ / Tab    在分类栏与功能栏之间切换"
    "  空格         勾选/取消（分类栏上为整类全选/全不选）"
    "  回车         执行已勾选项；未勾选时执行当前功能（执行前显示完整预演并确认）"
    "  d            生成执行计划预演（只读检测，不改系统）"
    "  /            搜索功能（名称/模块名/说明），回车确认，Esc 取消"
    "  l            查看当前模块最近一次执行日志     r  重新检测全部状态"
    "  ?            本帮助                           q  退出"
    ""
    "状态"
    "  ● 已应用/运行中   ◐ 部分完成   ○ 未安装/未配置   ⚠ 需注意   ✖ 异常   ? 未知（未提供检测）"
    ""
    "预演"
    "  + 安装 包   ~ 修改 文件   * 服务   # 端口   @ 定时任务   & 用户   ! 风险   · 说明"
    ""
    "其他"
    "  旧版界面：DEBNAS_UI=classic debnas        非 TTY 环境自动使用旧版界面"
    "  DebNAS — 将 Debian 快速配置成准 NAS 系统。作者 kekylin · https://github.com/kekylin/debnas"
  )
}

# 打开日志覆盖层（当前模块最近日志，否则最新日志）
_dash_open_log() {
  local dir="${DEBNAS_LOG_DIR:-/var/log/debnas}" file="" m="" f
  [[ -d "$dir" ]] || dir="/tmp/debnas-logs-${EUID:-0}"
  if [[ ${#_DASH_LIST[@]} -gt 0 && "${_DASH_LIST[$_DASH_FOCUS]}" == m:* ]]; then
    m="${_DASH_LIST[$_DASH_FOCUS]#m:}"
  fi
  if [[ -d "$dir" ]]; then
    if [[ -n "$m" ]]; then
      for f in "$dir/${m}"-*.log; do [[ -f "$f" && ( -z "$file" || "$f" -nt "$file" ) ]] && file="$f"; done
    fi
    if [[ -z "$file" ]]; then
      for f in "$dir"/*.log; do [[ -f "$f" && ( -z "$file" || "$f" -nt "$file" ) ]] && file="$f"; done
    fi
  fi
  _DASH_OVERLAY="log" _DASH_OVERLAY_OFF=0 _DASH_OVERLAY_LINES=()
  if [[ -z "$file" ]]; then
    _DASH_OVERLAY_TITLE="${dir}"
    _DASH_OVERLAY_LINES=("暂无日志（${dir}）")
    return 0
  fi
  _DASH_OVERLAY_TITLE="$file"
  local line
  while IFS= read -r line; do
    _DASH_OVERLAY_LINES+=("$(ui_str_sanitize "$line")")
  done < <(tail -n 500 "$file" 2>/dev/null)
  _DASH_OVERLAY_OFF=${#_DASH_OVERLAY_LINES[@]}
}

# 执行：离开全屏 → 完整预演 + 确认 → 流式执行 → 汇总 → 返回
_dash_execute() {
  local IFS=$'\n\t'
  local -a keys
  mapfile -t keys < <(_dash_selected_keys)
  if [[ ${#keys[@]} -eq 0 || -z "${keys[0]}" ]]; then
    if (( _DASH_PANE == 1 )) && [[ ${#_DASH_LIST[@]} -gt 0 ]]; then
      keys=("${_DASH_LIST[$_DASH_FOCUS]}")
    else
      _DASH_PANE=1
      return 0
    fi
  fi
  local -a mods
  mapfile -t mods < <(_dash_expand_modules "${keys[@]}")
  [[ ${#mods[@]} -gt 0 && -n "${mods[0]}" ]] || { _DASH_MSG="没有可执行的模块"; return 0; }

  _DASH_MSG="正在生成预演…"; ui_dashboard_render; _DASH_MSG=""
  local saved_sig="$_DASH_PLAN_SIG"
  _dash_build_plan "${keys[@]}"
  # 单项执行（未勾选）时预演签名不代表勾选状态，恢复
  [[ -n "${_DASH_SEL[${keys[0]}]:-}" ]] || _DASH_PLAN_SIG="$saved_sig"

  _dash_tui_leave
  trap ':' INT
  local i line
  printf '\n%sDebNAS · 执行计划%s（%d 个模块）\n\n' "$_DC_ACC" "$_DC_RESET" "${#mods[@]}"
  for i in "${!mods[@]}"; do
    printf '  %d. %s %s(%s)%s\n' "$(( i + 1 ))" "${_DASH_ITEM_NAME[m:${mods[$i]}]:-${mods[$i]}}" "$_DC_DIM" "${mods[$i]}" "$_DC_RESET"
  done
  printf '\n%s预演%s\n' "$_DC_ACC" "$_DC_RESET"
  local type rest target note
  for line in "${_DASH_PLAN[@]}"; do
    type="${line%%|*}"; rest="${line#*|}"; target="${rest%%|*}"; note="${rest#*|}"
    _dash_plan_label "$type"
    printf '  %s%s%s  %s  %s%s%s\n' "$_DASH_PC" "$_DASH_PT" "$_DC_RESET" "$target" "$_DC_DIM" "$note" "$_DC_RESET"
  done
  printf '\n'

  local ans="n"
  if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
    ans="y"
  else
    printf '确认执行以上 %d 个模块？[y/N] ' "${#mods[@]}"
    IFS= read -r -n 1 ans </dev/tty || ans="n"
    printf '\n'
  fi
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    printf '已取消。\n'
    _dash_tui_enter
    trap '_DASH_QUIT=1' INT
    _DASH_MSG="已取消执行"
    return 0
  fi

  local -A failed=()
  local -a results=()
  local m rc dep p skip runner="$_DASH_RUNNER" total=${#mods[@]}
  ui_utf8_restore
  for i in "${!mods[@]}"; do
    m="${mods[$i]}"
    skip=""
    get_module_field_var dep "$m" "depend_modules" || dep=""
    if [[ -n "$dep" ]]; then
      local -a deps=()
      IFS=' ,' read -ra deps <<< "$dep"
      for p in "${deps[@]}"; do [[ -n "$p" && -n "${failed[$p]:-}" ]] && skip="$p"; done
    fi
    printf '\n%s━━ [%d/%d] %s (%s) ━━%s\n' "$_DC_ACC" "$(( i + 1 ))" "$total" "${_DASH_ITEM_NAME[m:$m]:-$m}" "$m" "$_DC_RESET"
    if [[ -n "$skip" ]]; then
      failed["$m"]=1
      results+=("skip|${m}|依赖 ${skip} 未成功")
      printf '%s跳过：依赖模块 %s 未成功%s\n' "$_DC_WARN" "$skip" "$_DC_RESET"
      continue
    fi
    rc=0
    (unset _DEBNAS_BOOTSTRAPPED DEBNAS_MODULE_ACTION; trap - INT; bash "$runner" "$m") || rc=$?
    if [[ $rc -eq 0 ]]; then
      results+=("ok|${m}|")
    else
      failed["$m"]=1
      results+=("fail|${m}|退出码 ${rc}")
    fi
  done
  ui_utf8_ensure || true

  printf '\n%s执行结果%s\n' "$_DC_ACC" "$_DC_RESET"
  local r st mm why okn=0
  for r in "${results[@]}"; do
    st="${r%%|*}"; rest="${r#*|}"; mm="${rest%%|*}"; why="${rest#*|}"
    case "$st" in
      ok)   printf '  %s✔%s %s\n' "$_DC_OK" "$_DC_RESET" "${_DASH_ITEM_NAME[m:$mm]:-$mm}"; okn=$(( okn + 1 ))
            [[ -n "${_DASH_SEL[m:$mm]:-}" ]] && unset "_DASH_SEL[m:$mm]" ;;
      fail) printf '  %s✖%s %s  %s%s%s\n' "$_DC_BAD" "$_DC_RESET" "${_DASH_ITEM_NAME[m:$mm]:-$mm}" "$_DC_DIM" "$why" "$_DC_RESET" ;;
      *)    printf '  %s–%s %s  %s%s%s\n' "$_DC_WARN" "$_DC_RESET" "${_DASH_ITEM_NAME[m:$mm]:-$mm}" "$_DC_DIM" "$why" "$_DC_RESET" ;;
    esac
  done
  # 方案条目：全部成员成功则取消勾选
  local key all
  for key in "${keys[@]}"; do
    [[ "$key" == s:* ]] || continue
    all=1
    for mm in ${_DASH_ITEM_MODS[$key]:-}; do [[ -n "${failed[$mm]:-}" ]] && all=0; done
    (( all )) && unset "_DASH_SEL[$key]"
  done
  printf '\n  成功 %d / 共 %d    日志目录：%s\n' "$okn" "$total" "${DEBNAS_LOG_DIR:-/var/log/debnas}"
  printf '\n%s按任意键返回仪表盘…%s' "$_DC_DIM" "$_DC_RESET"
  IFS= read -rsn1 _ </dev/tty || true
  printf '\n'

  _dash_tui_enter
  trap '_DASH_QUIT=1' INT
  _DASH_PLAN=() _DASH_PLAN_SIG=""
  module_status_collect_start "$_DASH_DIR" "${mods[@]}"
  _DASH_MSG="已执行 ${total} 个模块：成功 ${okn}，正在刷新状态…"
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 按键处理
# ═══════════════════════════════════════════════════════════════

_dash_move() {
  local delta="$1"
  if (( _DASH_PANE == 1 )); then
    local n=${#_DASH_LIST[@]}
    (( n > 0 )) || return 0
    _DASH_FOCUS=$(( _DASH_FOCUS + delta ))
    (( _DASH_FOCUS < 0 )) && _DASH_FOCUS=0
    (( _DASH_FOCUS >= n )) && _DASH_FOCUS=$(( n - 1 ))
  else
    if (( _DASH_SEARCH_MODE > 0 )); then
      _DASH_SEARCH_MODE=0
      _DASH_QUERY=""
    fi
    local n=${#_DASH_CAT_NAME[@]} old=$_DASH_CAT
    _DASH_CAT=$(( _DASH_CAT + delta ))
    (( _DASH_CAT < 0 )) && _DASH_CAT=0
    (( _DASH_CAT >= n )) && _DASH_CAT=$(( n - 1 ))
    (( old != _DASH_CAT )) && { _DASH_FOCUS=0; _DASH_SCROLL=0; }
  fi
  return 0
}

# 处理一个按键（拆出便于测试）
ui_dashboard_handle_key() {
  local key="$1"
  [[ "$key" == "TIMEOUT" ]] && return 0
  _DASH_MSG=""

  # 覆盖层：日志可滚动，其它键关闭
  if [[ -n "$_DASH_OVERLAY" ]]; then
    case "$key" in
      UP)   _DASH_OVERLAY_OFF=$(( _DASH_OVERLAY_OFF - 1 )) ;;
      DOWN) _DASH_OVERLAY_OFF=$(( _DASH_OVERLAY_OFF + 1 )) ;;
      PGUP) _DASH_OVERLAY_OFF=$(( _DASH_OVERLAY_OFF - 10 )) ;;
      PGDN) _DASH_OVERLAY_OFF=$(( _DASH_OVERLAY_OFF + 10 )) ;;
      EOF)  _DASH_QUIT=1 ;;
      *)    _DASH_OVERLAY="" ;;
    esac
    return 0
  fi

  # 搜索输入
  if (( _DASH_SEARCH_MODE == 1 )); then
    case "$key" in
      ESC)       _DASH_SEARCH_MODE=0; _DASH_QUERY=""; _DASH_FOCUS=0; _DASH_SCROLL=0 ;;
      ENTER)     _DASH_SEARCH_MODE=2; _DASH_PANE=1 ;;
      BACKSPACE) _DASH_QUERY="${_DASH_QUERY%?}"; _DASH_FOCUS=0; _DASH_SCROLL=0 ;;
      UP)        _DASH_PANE=1; _dash_move -1 ;;
      DOWN)      _DASH_PANE=1; _dash_move 1 ;;
      SPACE)     _DASH_QUERY+=" "; _DASH_FOCUS=0 ;;
      CHAR:*)    _DASH_QUERY+="${key#CHAR:}"; _DASH_FOCUS=0; _DASH_SCROLL=0 ;;
      EOF)       _DASH_QUIT=1 ;;
    esac
    return 0
  fi

  case "$key" in
    UP|CHAR:k)   _dash_move -1 ;;
    DOWN|CHAR:j) _dash_move 1 ;;
    PGUP)        _dash_move -10 ;;
    PGDN)        _dash_move 10 ;;
    HOME)        _dash_move -9999 ;;
    END)         _dash_move 9999 ;;
    RIGHT)       _DASH_PANE=1 ;;
    LEFT)        _DASH_PANE=0 ;;
    TAB)         _DASH_PANE=$(( 1 - _DASH_PANE )) ;;
    ESC)
      if (( _DASH_SEARCH_MODE > 0 )); then
        _DASH_SEARCH_MODE=0; _DASH_QUERY=""; _DASH_FOCUS=0; _DASH_SCROLL=0
      else
        _DASH_PANE=0
      fi
      ;;
    SPACE)       _dash_action_space ;;
    ENTER)       _dash_execute ;;
    CHAR:d|CHAR:D)
      if (( ${#_DASH_SEL[@]} == 0 )); then
        _DASH_MSG="请先用空格勾选要执行的功能"
      else
        _DASH_MSG="正在生成预演…"; ui_dashboard_render; _DASH_MSG=""
        _dash_build_plan
        _DASH_MSG="预演已更新：${#_DASH_PLAN[@]} 条，其中风险 ${_DASH_PLAN_RISKS} 条"
      fi
      ;;
    CHAR:/)      _DASH_SEARCH_MODE=1; _DASH_PANE=0; _DASH_FOCUS=0; _DASH_SCROLL=0 ;;
    CHAR:l|CHAR:L) _dash_open_log ;;
    CHAR:\?)     _dash_open_help ;;
    CHAR:r|CHAR:R)
      local -a all=() k
      for k in "${_DASH_KEYS_ALL[@]}"; do [[ "$k" == m:* ]] && all+=("${k#m:}"); done
      module_status_collect_start "$_DASH_DIR" "${all[@]}"
      _DASH_MSG="正在重新检测全部状态…"
      ;;
    CHAR:q|CHAR:Q|EOF) _DASH_QUIT=1 ;;
  esac
  return 0
}

# ═══════════════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════════════

# 初始化（不进入全屏，可单独用于渲染冒烟测试）
# 参数：$1 — 缓存目录（可选），$2 — 项目根目录（可选）
ui_dashboard_init() {
  _DASH_ROOT="${2:-${_DEBNAS_ROOT:-${DEBNAS_ROOT:-}}}"
  _DASH_RUNNER="${_DASH_ROOT}/bin/module-runner.sh"
  _DASH_DIR="${1:-}"
  if [[ -z "$_DASH_DIR" || ! -d "$_DASH_DIR" ]]; then
    _DASH_DIR=$(mktemp -d 2>/dev/null) || return 1
  fi
  _dash_init_colors
  _DASH_CAT=0 _DASH_PANE=0 _DASH_FOCUS=0 _DASH_SCROLL=0 _DASH_CSCROLL=0
  _DASH_SEARCH_MODE=0 _DASH_QUERY="" _DASH_OVERLAY="" _DASH_MSG="" _DASH_QUIT=0
  _DASH_SEL=() _DASH_PLAN=() _DASH_PLAN_SIG=""
  _dash_build_model || return 1
  # 默认停在第一个模块分类（一键部署仍是第一项）
  [[ "${_DASH_CAT_KIND[0]}" == "sol" && ${#_DASH_CAT_NAME[@]} -gt 1 ]] && _DASH_CAT=1
  ui_sysinfo_static
  ui_sysinfo_sample 1
  return 0
}

# 仪表盘主入口（bin/menu.sh 调用）
# 返回：0 用户正常退出
ui_dashboard_main() {
  ui_dashboard_init "${1:-}" || return 1
  local -a all=() k
  for k in "${_DASH_KEYS_ALL[@]}"; do [[ "$k" == m:* ]] && all+=("${k#m:}"); done
  module_status_collect_start "$_DASH_DIR" "${all[@]}"
  ui_sysinfo_updates_start "${_DASH_DIR}/updates.count"

  _dash_install_traps
  _dash_layout
  _dash_tui_enter
  _DASH_LAST_SAMPLE=${EPOCHSECONDS:-0}
  _DASH_LAST_DISK=${EPOCHSECONDS:-0}

  local timeout now pending=1
  while (( _DASH_QUIT == 0 )); do
    if (( _DASH_RESIZED )); then
      _DASH_RESIZED=0
      _dash_layout
      printf '\e[H\e[2J'
      _DASH_PREV=()
    fi
    module_status_collect_poll && pending=0 || pending=1
    ui_sysinfo_updates_poll || pending=1
    ui_dashboard_render
    if (( pending )); then timeout=0.2; else timeout=1; fi
    _dash_read_key "$timeout"
    ui_dashboard_handle_key "$_DASH_KEY"
    now=${EPOCHSECONDS:-0}
    if (( now - _DASH_LAST_SAMPLE >= 2 )); then
      local with_disk=0
      (( now - _DASH_LAST_DISK >= 10 )) && { with_disk=1; _DASH_LAST_DISK=$now; }
      ui_sysinfo_sample "$with_disk"
      _DASH_LAST_SAMPLE=$now
    fi
  done

  _dash_tui_leave
  module_status_collect_stop
  ui_sysinfo_updates_stop
  trap - WINCH
  trap ':' INT
  return 0
}
