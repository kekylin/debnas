#!/usr/bin/env bats
# 测试: lib/ui/dashboard.sh — 方案 A 双栏仪表盘（布局合成 / 边框对齐 / 窄屏退化 / 按键 / 搜索 / 预演 / 执行顺序）
# 技术: 临时模块目录 + 假项目根（config/solutions）+ NO_COLOR 合成帧后去转义比对显示宽度

load '../../helpers/common-setup'

TEST_MODULES_DIR="$BATS_TMPDIR/dash-modules"
mkdir -p "$TEST_MODULES_DIR"
export DEBNAS_MODULES_DIR="$TEST_MODULES_DIR"

# 写一个带守卫的夹具模块
# $1 名称 $2 显示名 $3 分类 $4 depend_modules $5 status 行 $6 plan 行（\n 分隔）
make_mod() {
  cat > "$TEST_MODULES_DIR/$1.sh" << EOF
#!/bin/bash
# @module: $1
# @name: $2
# @category: $3
# @depend_modules: $4
# @order: 10
# 功能：$2 的功能说明
module_status() { echo "$5"; }
module_plan() { printf '%b\n' "$6"; }
main() { touch "\$MARKER"; }
if [[ "\${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "\$@"; fi
EOF
}

setup() {
  export LC_ALL=C.UTF-8
  export NO_COLOR=1
  export DEBNAS_STATE_DIR="$BATS_TMPDIR/dash-state"
  rm -rf "$TEST_MODULES_DIR" "$DEBNAS_STATE_DIR"
  mkdir -p "$TEST_MODULES_DIR" "$DEBNAS_STATE_DIR"
  MARKER="$BATS_TMPDIR/dash-main-ran"; rm -f "$MARKER"; export MARKER

  make_mod firewall "安装 Firewalld" "安全防护" "" "absent|未安装" 'pkg|firewalld ipset|apt\nwrite|/etc/firewalld/zones/public.xml|备份到 /var/backups\nrisk|SSH|不会断连'
  make_mod fail2ban "安装 Fail2ban" "安全防护" "firewall" "running|jail: sshd" 'pkg|fail2ban ipset|apt'
  make_mod security "基础安全配置" "安全防护" "" "applied|禁 root 远程" ''
  make_mod docker-ce "安装 Docker CE" "容器管理" "" "warn|已安装未运行" 'service|docker|启动'

  FAKE_ROOT="$BATS_TMPDIR/dash-root"
  rm -rf "$FAKE_ROOT"; mkdir -p "$FAKE_ROOT/config/solutions" "$FAKE_ROOT/bin"
  printf '# 安全套餐\nfirewall\nfail2ban\n' > "$FAKE_ROOT/config/solutions/secure.list"

  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  source "${DEBNAS_ROOT}/lib/system/state.sh"
  source "${DEBNAS_ROOT}/lib/system/module-registry.sh"
  source "${DEBNAS_ROOT}/lib/system/module-probe.sh"
  source "${DEBNAS_ROOT}/lib/ui/textwidth.sh"
  source "${DEBNAS_ROOT}/lib/ui/sysinfo.sh"
  source "${DEBNAS_ROOT}/lib/ui/dashboard.sh"
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  _DEBNAS_BOOTSTRAPPED=1
  discover_modules 2>/dev/null

  SOLUTION_NAMES=(secure)
  SOLUTION_DISPLAY_NAMES=("安全套餐")
  CACHE_DIR="$BATS_TMPDIR/dash-cache"; rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
  ui_dashboard_init "$CACHE_DIR" "$FAKE_ROOT"
  _MODULE_STATUS=(
    [firewall]="absent|未安装"
    [fail2ban]="running|jail: sshd"
    [security]="applied|禁 root 远程"
    [docker-ce]="warn|已安装未运行"
  )
  _SI_UPDATES=12
}

teardown() {
  module_status_collect_stop 2>/dev/null || true
  rm -rf "$TEST_MODULES_DIR" "$DEBNAS_STATE_DIR" "$FAKE_ROOT" "$CACHE_DIR"
  rm -f "$MARKER"
}

# 去掉 ANSI 转义后逐行求显示宽度，全部等于期望值才返回 0
frame_widths_ok() {
  local want="$1" l plain
  for l in "${_DASH_FRAME[@]}"; do
    [[ -z "$l" ]] && continue
    plain=$(printf '%s' "$l" | sed 's/\x1b\[[0-9;]*m//g')
    ui_str_width "$plain"
    if [[ "$_UI_W" -ne "$want" ]]; then
      echo "宽度 $_UI_W ≠ $want: $plain" >&2
      return 1
    fi
  done
}

frame_text() {
  local l
  for l in "${_DASH_FRAME[@]}"; do printf '%s\n' "$l"; done | sed 's/\x1b\[[0-9;]*m//g'
}

# ==================== 模型 ====================

@test "模型: 一键部署为第一个分类，其后按 CATEGORY_ORDER" {
  [ "${_DASH_CAT_NAME[0]}" = "⚡ 一键部署" ]
  [ "${_DASH_CAT_NAME[1]}" = "安全防护" ]
  [ "${_DASH_CAT_NAME[2]}" = "容器管理" ]
  [ "${_DASH_CAT_LEN[1]}" -eq 3 ]
}

@test "模型: 默认停在第一个模块分类" {
  [ "$_DASH_CAT" -eq 1 ]
}

@test "模型: 说明回退读取 '# 功能：' 注释" {
  [ "${_DASH_ITEM_DESC[m:firewall]}" = "安装 Firewalld 的功能说明" ]
}

@test "分类完成度: applied/running 计为完成" {
  _dash_cat_count 1
  [ "$_DASH_CNT_TEXT" = "2/3" ]
}

@test "方案状态: 由成员模块汇总" {
  _dash_item_status "s:secure"
  [ "$_DASH_ST_CODE" = "partial" ]
  [ "$_DASH_ST_DESC" = "1/2 个模块已完成" ]
}

# ==================== 布局与对齐 ====================

@test "布局: 120x40 为双栏，所有行显示宽度 = 119（边框对齐）" {
  _dash_layout_set 120 40
  [ "$_DASH_MODE" = "wide" ]
  ui_dashboard_compose
  frame_widths_ok 119
  frame_text | grep -c "╭─ DebNAS" >/dev/null
  frame_text | grep -c "╭─ 分类" >/dev/null
  frame_text | grep -c "执行计划 · 预演" >/dev/null
  frame_text | grep -c "/ 搜索功能…" >/dev/null
}

@test "布局: 100x28 仍为双栏且对齐" {
  _dash_layout_set 100 28
  [ "$_DASH_MODE" = "wide" ]
  ui_dashboard_compose
  frame_widths_ok 99
  [ "${#_DASH_FRAME[@]}" -le 28 ]
}

@test "布局: 99 列退化为单栏" {
  _dash_layout_set 99 40
  [ "$_DASH_MODE" = "narrow" ]
  ui_dashboard_compose
  frame_widths_ok 98
  ! frame_text | grep -c "╭─ DebNAS" >/dev/null
}

@test "布局: 27 行退化为单栏，帧不超过屏幕行数" {
  _dash_layout_set 120 27
  [ "$_DASH_MODE" = "narrow" ]
  ui_dashboard_compose
  [ "${#_DASH_FRAME[@]}" -le 27 ]
  frame_widths_ok 119
}

@test "布局: 单栏第二级显示状态列与勾选框" {
  _dash_layout_set 80 24
  _DASH_PANE=1
  _DASH_SEL[m:firewall]=1
  ui_dashboard_compose
  frame_text | grep -c "\[✓\] 安装 Firewalld" >/dev/null
  frame_text | grep -c "○ 未安装" >/dev/null
  frame_widths_ok 79
}

@test "布局: 过小终端给出提示" {
  _dash_layout_set 30 10
  [ "$_DASH_MODE" = "tiny" ]
  ui_dashboard_compose
  frame_text | grep -c "终端太小" >/dev/null
}

@test "布局: 状态文字与颜色映射" {
  _dash_status_view running;  [ "$_DASH_SV_TEXT" = "● 运行中" ]
  _dash_status_view absent;   [ "$_DASH_SV_TEXT" = "○ 未安装" ]
  _dash_status_view absent "未安装 firewalld";   [ "$_DASH_SV_TEXT" = "○ 未安装" ]
  _dash_status_view absent "未配置 su 限制";     [ "$_DASH_SV_TEXT" = "○ 未配置" ]
  _dash_status_view absent "未启用 Hosts 同步";  [ "$_DASH_SV_TEXT" = "○ 未配置" ]
  _dash_status_view warn;     [ "$_DASH_SV_TEXT" = "⚠ 需注意" ]
  _dash_status_view error;    [ "$_DASH_SV_TEXT" = "✖ 异常" ]
  _dash_status_view whatever; [ "$_DASH_SV_TEXT" = "? 未知" ]
}

@test "布局: 长说明截断后仍对齐" {
  _MODULE_STATUS[firewall]="absent|$(printf '很长的说明%.0s' {1..40})"
  _dash_layout_set 120 40
  ui_dashboard_compose
  frame_widths_ok 119
}

# ==================== 差量刷新 ====================

@test "刷新: 第二次 flush 无变化时不输出任何内容" {
  _dash_layout_set 120 40
  ui_dashboard_compose
  _dash_flush > /dev/null
  ui_dashboard_compose
  run _dash_flush
  [ -z "$output" ]
}

@test "刷新: 移动焦点只重绘变化的行" {
  _dash_layout_set 120 40
  _DASH_PANE=1
  ui_dashboard_compose
  _dash_flush > /dev/null
  ui_dashboard_handle_key DOWN
  ui_dashboard_compose
  local n
  n=$(_dash_flush | grep -o $'\e\[[0-9]*;1H' | wc -l)
  [ "$n" -gt 0 ]
  [ "$n" -lt 8 ]
}

# ==================== 按键 ====================

@test "按键: 方向键与空格勾选" {
  ui_dashboard_handle_key RIGHT
  [ "$_DASH_PANE" -eq 1 ]
  _dash_build_list
  ui_dashboard_handle_key SPACE
  [ -n "${_DASH_SEL[m:security]:-}" ] || [ -n "${_DASH_SEL[${_DASH_LIST[0]}]:-}" ]
  [ "$_DASH_FOCUS" -eq 1 ]
  ui_dashboard_handle_key LEFT
  [ "$_DASH_PANE" -eq 0 ]
}

@test "按键: 分类栏空格整类全选/全不选" {
  _dash_build_list
  ui_dashboard_handle_key SPACE
  [ "${#_DASH_SEL[@]}" -eq 3 ]
  ui_dashboard_handle_key SPACE
  [ "${#_DASH_SEL[@]}" -eq 0 ]
}

@test "按键: 上下切换分类并重置焦点" {
  _DASH_FOCUS=2
  ui_dashboard_handle_key DOWN
  [ "$_DASH_CAT" -eq 2 ]
  [ "$_DASH_FOCUS" -eq 0 ]
  ui_dashboard_handle_key UP
  ui_dashboard_handle_key UP
  [ "$_DASH_CAT" -eq 0 ]
}

@test "按键: / 搜索实时过滤，Esc 取消" {
  ui_dashboard_handle_key CHAR:/
  [ "$_DASH_SEARCH_MODE" -eq 1 ]
  ui_dashboard_handle_key CHAR:d
  ui_dashboard_handle_key CHAR:o
  ui_dashboard_handle_key CHAR:c
  _dash_build_list
  [ "${#_DASH_LIST[@]}" -eq 1 ]
  [ "${_DASH_LIST[0]}" = "m:docker-ce" ]
  ui_dashboard_handle_key BACKSPACE
  [ "$_DASH_QUERY" = "do" ]
  ui_dashboard_handle_key ESC
  [ "$_DASH_SEARCH_MODE" -eq 0 ]
  [ -z "$_DASH_QUERY" ]
}

@test "按键: 搜索回车后焦点进入结果列表" {
  ui_dashboard_handle_key CHAR:/
  ui_dashboard_handle_key CHAR:f
  ui_dashboard_handle_key ENTER
  [ "$_DASH_SEARCH_MODE" -eq 2 ]
  [ "$_DASH_PANE" -eq 1 ]
}

@test "按键: 搜索大小写不敏感，并匹配中文说明" {
  _DASH_SEARCH_MODE=1; _DASH_QUERY="FIREWALLD"
  _dash_build_list
  printf "%s\n" "${_DASH_LIST[@]}" | grep -cx "m:firewall" >/dev/null
  _DASH_QUERY="功能说明"
  _dash_build_list
  [ "${#_DASH_LIST[@]}" -eq 4 ]
}

@test "按键: ? 打开帮助，任意键关闭" {
  ui_dashboard_handle_key CHAR:?
  [ "$_DASH_OVERLAY" = "help" ]
  _dash_layout_set 120 40
  ui_dashboard_compose
  frame_widths_ok 119
  ui_dashboard_handle_key CHAR:x
  [ -z "$_DASH_OVERLAY" ]
}

@test "按键: q 与 EOF 退出" {
  ui_dashboard_handle_key CHAR:q
  [ "$_DASH_QUIT" -eq 1 ]
  _DASH_QUIT=0
  ui_dashboard_handle_key EOF
  [ "$_DASH_QUIT" -eq 1 ]
}

@test "按键: d 无勾选时提示，不生成预演" {
  ui_dashboard_handle_key CHAR:d
  [[ "$_DASH_MSG" == *"勾选"* ]]
  [ "${#_DASH_PLAN[@]}" -eq 0 ]
}

@test "_dash_read_key: 解析方向键/回车/空格/普通字符/ESC" {
  _dash_read_key 1 < <(printf '\e[A'); [ "$_DASH_KEY" = "UP" ]
  _dash_read_key 1 < <(printf '\e[D'); [ "$_DASH_KEY" = "LEFT" ]
  _dash_read_key 1 < <(printf '\e[6~'); [ "$_DASH_KEY" = "PGDN" ]
  _dash_read_key 1 < <(printf '\n'); [ "$_DASH_KEY" = "ENTER" ]
  _dash_read_key 1 < <(printf ' '); [ "$_DASH_KEY" = "SPACE" ]
  _dash_read_key 1 < <(printf 'd'); [ "$_DASH_KEY" = "CHAR:d" ]
  _dash_read_key 1 < <(printf '\e'); [ "$_DASH_KEY" = "ESC" ]
  _dash_read_key 1 < <(printf '\x7f'); [ "$_DASH_KEY" = "BACKSPACE" ]
}

@test "_dash_read_key: EOF 与超时" {
  _dash_read_key 1 < /dev/null; [ "$_DASH_KEY" = "EOF" ]
  _dash_read_key 0.05 < <(sleep 1); [ "$_DASH_KEY" = "TIMEOUT" ]
}

# ==================== 预演与执行顺序 ====================

@test "执行顺序: 方案展开 + 去重 + 依赖在前" {
  run _dash_expand_modules "m:fail2ban" "s:secure" "m:firewall"
  [ "${lines[0]}" = "firewall" ]
  [ "${lines[1]}" = "fail2ban" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "预演: 合并包去重，风险排最后，且不执行任何模块 main" {
  _DASH_SEL[m:firewall]=1
  _DASH_SEL[m:fail2ban]=1
  _dash_build_plan
  [ "${_DASH_PLAN[0]}" = "pkg|firewalld ipset fail2ban|apt · 3 个包" ]
  [[ "${_DASH_PLAN[-1]}" == risk\|* ]]
  [ "$_DASH_PLAN_RISKS" -eq 1 ]
  [ ! -f "$MARKER" ]
}

@test "预演: 依赖未完成且未勾选时给出风险" {
  _DASH_SEL[m:fail2ban]=1
  _dash_build_plan
  printf '%s\n' "${_DASH_PLAN[@]}" | grep -c "依赖模块 firewall 尚未完成" >/dev/null
}

@test "预演: 选择变化后预演框提示按 d 刷新" {
  _DASH_SEL[m:firewall]=1
  _dash_build_plan
  _dash_plan_view 100 4
  printf '%s\n' "${_DASH_PLAN_VIEW[@]}" | sed 's/\x1b\[[0-9;]*m//g' | grep -c "+ 安装" >/dev/null
  _DASH_SEL[m:docker-ce]=1
  _dash_plan_view 100 4
  printf '%s\n' "${_DASH_PLAN_VIEW[@]}" | sed 's/\x1b\[[0-9;]*m//g' | grep -c "按 d 生成预演" >/dev/null
}

@test "预演: 条目过多时末行提示剩余条数" {
  _DASH_PLAN=(info\|a\|1 info\|b\|2 info\|c\|3 info\|d\|4 info\|e\|5)
  _DASH_SEL[m:firewall]=1
  _DASH_PLAN_SIG=$(_dash_selected_keys | tr '\n' ' ')
  _dash_plan_view 80 3
  [ "${#_DASH_PLAN_VIEW[@]}" -eq 3 ]
  printf '%s' "${_DASH_PLAN_VIEW[2]}" | sed 's/\x1b\[[0-9;]*m//g' | grep -c "另有 3 条" >/dev/null
}

# ==================== 入口判定 ====================

@test "ui_dashboard_available: DEBNAS_UI=classic 时回退旧界面" {
  DEBNAS_UI=classic run ui_dashboard_available
  [ "$status" -eq 1 ]
}

@test "ui_dashboard_available: 非 TTY 时回退旧界面" {
  run ui_dashboard_available < /dev/null
  [ "$status" -eq 1 ]
}

@test "终端恢复: _dash_tui_leave 未进入时为空操作" {
  _DASH_TUI_ON=0
  run _dash_tui_leave
  [ -z "$output" ]
}

@test "bin/menu.sh: 保留旧版 main_menu_loop 回退路径" {
  grep -q 'ui_dashboard_available' "${DEBNAS_ROOT}/bin/menu.sh"
  grep -q '^main_menu_loop()' "${DEBNAS_ROOT}/bin/menu.sh"
  grep -q '  main_menu_loop$' "${DEBNAS_ROOT}/bin/menu.sh"
}

@test "预演: 预演框放不下时优先保留风险行" {
  _DASH_PLAN=(info\|a\|1 info\|b\|2 info\|c\|3 info\|d\|4 risk\|SSH\|会断连)
  _DASH_SEL[m:firewall]=1
  _DASH_PLAN_SIG=$(_dash_selected_keys | tr '\n' ' ')
  _dash_plan_view 80 3
  printf '%s\n' "${_DASH_PLAN_VIEW[@]}" | sed 's/\x1b\[[0-9;]*m//g' | grep -c "! 风险  SSH：会断连" >/dev/null
  printf '%s' "${_DASH_PLAN_VIEW[2]}" | sed 's/\x1b\[[0-9;]*m//g' | grep -c "另有 3 条" >/dev/null
}

# ==================== absent 文案：未安装 / 未配置 ====================

@test "布局: absent 按 @kind 声明区分未安装/未配置，未声明时按说明前缀" {
  cat > "$TEST_MODULES_DIR/wallpaper.sh" << 'EOF'
#!/bin/bash
# @module: wallpaper
# @name: 登录壁纸
# @category: 安全防护
# @kind: config
module_status() { echo "absent|未安装 Cockpit"; }
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
EOF
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  discover_modules 2>/dev/null
  local k=""
  get_module_field_var k wallpaper kind
  [ "$k" = "config" ]
  # 声明 config：说明虽以"未安装"开头仍显示未配置
  _dash_status_view absent "未安装 Cockpit" wallpaper
  [ "$_DASH_SV_TEXT" = "○ 未配置" ]
  # 未声明：按说明前缀
  _dash_status_view absent "未安装 firewalld" firewall
  [ "$_DASH_SV_TEXT" = "○ 未安装" ]
  _dash_status_view absent "当前 cubic，未启用 BBR" firewall
  [ "$_DASH_SV_TEXT" = "○ 未配置" ]
  # 条目行使用模块元数据与说明
  _MODULE_STATUS[firewall]="absent|未配置 zone"
  _dash_item_line "m:firewall" 90
  [[ "$(printf '%s' "$_DASH_C" | sed 's/\x1b\[[0-9;]*m//g')" == *"○ 未配置"* ]]
}

# ==================== 预演：依赖模块同批先执行 ====================

@test "预演: 依赖模块在本次列表中且排在前面时，依赖缺失提示合并为一条 info" {
  make_mod docker-apps "部署容器应用" "容器管理" "docker-ce" "absent|未安装 Docker" \
    'info|docker|未安装 Docker，执行时会直接失败（请先运行 docker-ce 模块）\nrisk|docker|请先执行 docker-ce 模块\nservice|portainer|部署\ninfo|with|${DEBNAS_PLAN_WITH:-无}'
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  discover_modules 2>/dev/null
  ui_dashboard_init "$CACHE_DIR" "$FAKE_ROOT"
  _DASH_SEL[m:docker-ce]=1
  _DASH_SEL[m:docker-apps]=1
  _dash_build_plan
  local all
  all=$(printf '%s\n' "${_DASH_PLAN[@]}")
  [[ "$all" != *"未安装 Docker，执行时会直接失败"* ]]
  [[ "$all" != *"请先执行 docker-ce 模块"* ]]
  [ "$(grep -c '将先执行依赖「安装 Docker CE」（docker-ce）' <<<"$all")" -eq 1 ]
  [[ "$all" == *"service|portainer|部署"* ]]
  # 本次执行列表经 DEBNAS_PLAN_WITH 传给模块（依赖在前）
  [[ "$all" == *"info|with|docker-ce docker-apps"* ]]
  [ "$_DASH_PLAN_RISKS" -eq 0 ]
}

@test "预演: 只勾选下游模块时保留模块自己的依赖缺失提示" {
  make_mod docker-apps "部署容器应用" "容器管理" "docker-ce" "absent|未安装 Docker" \
    'info|docker|未安装 Docker，执行时会直接失败（请先运行 docker-ce 模块）'
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  discover_modules 2>/dev/null
  ui_dashboard_init "$CACHE_DIR" "$FAKE_ROOT"
  _DASH_SEL[m:docker-apps]=1
  _dash_build_plan
  local all
  all=$(printf '%s\n' "${_DASH_PLAN[@]}")
  [[ "$all" == *"未安装 Docker，执行时会直接失败"* ]]
  [[ "$all" != *"将先执行依赖"* ]]
  [[ "$all" == *"依赖模块 docker-ce 尚未完成且未勾选"* ]]
}

@test "_dash_plan_mentions_dep: 只认「模块名 模块」或「显示名」，不误匹配前缀相同的模块名" {
  _dash_plan_mentions_dep "risk|x|请先执行 firewall 模块" firewall
  _dash_plan_mentions_dep "risk|x|先运行「安装 Firewalld」" firewall
  ! _dash_plan_mentions_dep "risk|x|请先执行 xfirewall 模块" firewall
  ! _dash_plan_mentions_dep "write|/etc/x|firewall 模块放行" firewall
  ! _dash_plan_mentions_dep "info|x|与防火墙无关" firewall
}

# ==================== 焦点行高亮连续 ====================

@test "高亮: 焦点行去掉灰色前景，每个 reset 后重开背景，整行背景连续" {
  unset NO_COLOR
  _dash_init_colors
  _dash_box_row 20 "${_DC_DIM}[ ]${_DC_RESET} 名称  ${_DC_DIM}○ 未安装${_DC_RESET}  ${_DC_DIM}说明${_DC_RESET}" 1
  local inner="${_DASH_L#"${_DC_BORDER}│${_DC_RESET}"}"
  inner="${inner%"${_DC_BORDER}│${_DC_RESET}"}"
  [[ "$inner" != *$'\e[90m'* ]]
  # 去掉末尾收尾的 reset 后，其余每个 reset 紧跟背景色
  inner="${inner%$'\e[0m'}"
  local rest="$inner" n=0
  while [[ "$rest" == *$'\e[0m'* ]]; do
    rest="${rest#*$'\e[0m'}"
    [[ "$rest" == $'\e[44m'* ]]
    n=$(( n + 1 ))
  done
  [ "$n" -ge 3 ]
  # 非焦点行保持原样
  _dash_box_row 20 "${_DC_DIM}x${_DC_RESET}" 0
  [[ "$_DASH_L" == *$'\e[90mx'* ]]
}

# ==================== 信号：SIGHUP / SIGTSTP / SIGCONT ====================

@test "信号: 安装 HUP/TSTP/CONT 处理；SIGHUP 终止后台探测、恢复终端后以 129 退出" {
  run bash -c '
    source "$1/lib/core/constants.sh"; source "$1/lib/core/colors.sh"; source "$1/lib/core/logging.sh"
    source "$1/lib/system/utils.sh"; source "$1/lib/ui/textwidth.sh"; source "$1/lib/ui/sysinfo.sh"; source "$1/lib/ui/dashboard.sh"
    module_status_collect_stop() { echo STOP_PROBE; }
    ui_sysinfo_updates_stop() { echo STOP_UPDATES; }
    _dash_tui_leave() { echo LEAVE; }
    _dash_install_traps
    trap -p HUP TSTP CONT
    kill -HUP $$
    sleep 1
    echo NOT_EXITED' _ "$DEBNAS_ROOT"
  [[ "$status" -eq 129 ]]
  [[ "$output" == *"_dash_on_hup"*"_dash_on_tstp"*"_dash_on_cont"* ]]
  [[ "$output" == *STOP_PROBE*STOP_UPDATES*LEAVE* ]]
  [[ "$output" != *NOT_EXITED* ]]
}

@test "信号: SIGTSTP 暂停前恢复终端，继续后重新进入 TUI 并整屏重绘；非 TUI 状态不进入" {
  local calls=""
  _dash_tui_leave() { calls+="leave "; _DASH_TUI_ON=0; }
  _dash_tui_enter() { calls+="enter "; _DASH_TUI_ON=1; }
  kill() { calls+="kill:$1 "; }
  _DASH_TUI_ON=1; _DASH_RESIZED=0
  _dash_on_tstp
  [[ "$calls" == "leave kill:-STOP enter " ]]
  [[ "$_DASH_RESIZED" -eq 1 ]]
  calls=""; _DASH_TUI_ON=0; _DASH_RESIZED=0
  _dash_on_tstp
  [[ "$calls" != *enter* && "$_DASH_RESIZED" -eq 0 ]]
  unset -f kill
}

@test "信号: SIGCONT 在 TUI 中时整屏重绘" {
  _DASH_TUI_ON=1; _DASH_RESIZED=0
  _dash_on_cont >/dev/null
  [[ "$_DASH_RESIZED" -eq 1 ]]
  _DASH_TUI_ON=0; _DASH_RESIZED=0
  _dash_on_cont
  [[ "$_DASH_RESIZED" -eq 0 ]]
}

# ==================== 按内容分配行：功能栏 / 预演框（2026-11-10） ====================

# 往指定分类追加 N 个夹具模块（名称前缀 $1），重建模型并停在该分类的功能栏
# $1 前缀 $2 分类 $3 个数 $4 说明后缀（可选，用于制造超长说明）
use_category() {
  local prefix="$1" cat="$2" n="$3" tail="${4:-}" i
  for (( i = 1; i <= n; i++ )); do
    make_mod "${prefix}${i}" "功能${prefix}${i}${tail}" "$cat" "" "absent|未安装" ''
  done
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  discover_modules 2>/dev/null
  ui_dashboard_init "$CACHE_DIR" "$FAKE_ROOT"
  for (( i = 0; i < ${#_DASH_CAT_NAME[@]}; i++ )); do
    [[ "${_DASH_CAT_NAME[i]}" == "$cat" ]] && _DASH_CAT=$i
  done
  _DASH_PANE=1 _DASH_FOCUS=0 _DASH_SCROLL=0
  _dash_build_list
}

# 勾选当前列表第一项并放入 N 条与勾选一致的预演
set_plan() {
  local n="$1" i
  _DASH_SEL["${_DASH_LIST[0]}"]=1
  _DASH_PLAN=()
  for (( i = 1; i <= n; i++ )); do _DASH_PLAN+=("write|/etc/demo/file${i}.conf|备份"); done
  _dash_sel_sig
  _DASH_PLAN_SIG="$_DASH_SIG"
}

# 标题为 $1 的框的内容行数（不含上下边框）
box_rows() {
  frame_text | awk -v t="╭─ $1" 'index($0, t) { on = 1; next } on && index($0, "╰") { print n + 0; exit } on { n++ }'
}

# 帧文本是否匹配正则（here-string，避免 pipefail 下 grep -q 提前退出触发 SIGPIPE）
frame_has() { grep -q -- "$1" <<< "$(frame_text)"; }

plan_shown() { frame_text | grep -c "~ 修改" || true; }

# 断言：帧恰好占满/不超过终端高度，且每行显示宽度一致
frame_fits() {
  [ "${#_DASH_FRAME[@]}" -le "$_DASH_ROWS" ]
  frame_widths_ok "$_DASH_W"
}

@test "分配: 80x24 未勾选时预演框保持最小 3 行，其余行归功能栏，帧占满 24 行" {
  _dash_layout_set 80 24
  _DASH_PANE=1
  ui_dashboard_compose
  frame_fits
  [ "${#_DASH_FRAME[@]}" -eq 24 ]
  [ "$(box_rows "执行计划 · 预演")" -eq 3 ]
  [ "$(box_rows "安全防护")" -eq 15 ]
}

@test "分配: 80x24 功能 2 个 + 12 条预演 → 12 条全部可见，功能栏收缩到内容高度" {
  use_category n "通知服务" 2
  _dash_layout_set 80 24
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "${#_DASH_FRAME[@]}" -eq 24 ]
  [ "$(plan_shown)" -eq 12 ]
  ! frame_has "另有"
  # 表头 1 + 功能 2 + 分隔线 1 + 详情 2 = 6
  [ "$(box_rows "通知服务")" -eq 6 ]
  [ "$(frame_text | grep -c '功能n[12] ')" -ge 2 ]
}

@test "分配: 80x24 功能 4 个 + 12 条预演 → 功能全部可见，预演 10 条 + 另有 2 条" {
  use_category n "通知服务" 4
  _dash_layout_set 80 24
  set_plan 12
  ui_dashboard_compose
  frame_fits
  # 功能栏下限 = 表头 + 4 + 分隔线 + 详情 1 = 7；预演框 18 - 7 = 11 行
  [ "$(box_rows "通知服务")" -eq 7 ]
  [ "$(box_rows "执行计划 · 预演")" -eq 11 ]
  [ "$(plan_shown)" -eq 10 ]
  frame_has "另有 2 条"
  [ "$(frame_text | grep -c '\[.\] 功能n[1-4] ')" -eq 4 ]
}

@test "分配: 80x24 功能 7 个 + 12 条预演 → 功能栏保留 5 行可滚动（↓ 提示），预演 9 条 + 另有 3 条" {
  use_category n "通知服务" 7
  _dash_layout_set 80 24
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "通知服务")" -eq 8 ]
  [ "$(plan_shown)" -eq 9 ]
  frame_has "另有 3 条"
  [ "$(frame_text | grep -c '\[.\] 功能n[1-7] ')" -eq 5 ]
  frame_has "┄ ↓"
  # 焦点移到末项：列表滚动，提示变为 ↑
  _DASH_FOCUS=6
  ui_dashboard_compose
  frame_fits
  frame_has "功能n7 "
  frame_has "┄ ↑"
}

@test "分配: 80x24 功能数超过可视行数时列表滚动、详情收为 1 行；有预演时仍给预演框让行" {
  use_category n "通知服务" 30
  _dash_layout_set 80 24
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "执行计划 · 预演")" -eq 3 ]
  # 15 行 = 表头 + 12 个功能 + 分隔线 + 详情 1
  [ "$(frame_text | grep -c '\[.\] 功能n[0-9]* ')" -eq 12 ]
  frame_has "┄ ↓"
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "${#_DASH_FRAME[@]}" -eq 24 ]
  [ "$(box_rows "通知服务")" -eq 8 ]
  [ "$(plan_shown)" -eq 9 ]
}

@test "分配: 勾选变化（预演过期）后预演框缩回最小，行还给功能栏" {
  use_category n "通知服务" 4
  _dash_layout_set 80 24
  set_plan 12
  ui_dashboard_compose
  [ "$(box_rows "执行计划 · 预演")" -eq 11 ]
  _DASH_SEL["${_DASH_LIST[1]}"]=1
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "执行计划 · 预演")" -eq 3 ]
  frame_has "按 d 生成预演"
  _DASH_SEL=()
  ui_dashboard_compose
  [ "$(box_rows "执行计划 · 预演")" -eq 3 ]
  [ "$(box_rows "通知服务")" -eq 15 ]
}

@test "分配: 单栏分类页同样给预演让行；不足 20 行时不显示预演框" {
  _dash_layout_set 80 24
  _DASH_PANE=1; _dash_build_list; set_plan 12; _DASH_PANE=0
  ui_dashboard_compose
  frame_fits
  # 预演 12 条全部可见；分类框占其余 6 行（3 个分类 + 搜索行，不低于下限 4）
  [ "$(box_rows "分类")" -eq 6 ]
  [ "$(box_rows "执行计划 · 预演")" -eq 12 ]
  [ "$(plan_shown)" -eq 12 ]
  set_plan 30
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "分类")" -eq 4 ]
  frame_has "另有 [0-9]* 条"
  _dash_layout_set 80 18
  ui_dashboard_compose
  frame_fits
  ! frame_has "执行计划"
  [ "${#_DASH_FRAME[@]}" -eq 18 ]
}

@test "分配: 100x30 单栏（列数不足 100）有预演时全部可见" {
  use_category n "通知服务" 4
  _dash_layout_set 99 30
  [ "$_DASH_MODE" = "narrow" ]
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "${#_DASH_FRAME[@]}" -eq 30 ]
  [ "$(plan_shown)" -eq 12 ]
  [ "$(box_rows "通知服务")" -eq 12 ]
}

@test "分配: 120x40 双栏高度随当前分类功能数变化，预演框未勾选 6 行、有预演时按条数扩展" {
  use_category n "通知服务" 7
  _dash_layout_set 120 40
  ui_dashboard_compose
  frame_fits
  # 表头 + 7 + 分隔线 + 详情 2 = 11
  [ "$(box_rows "分类")" -eq 11 ]
  [ "$(box_rows "执行计划 · 预演")" -eq 6 ]
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "执行计划 · 预演")" -eq 12 ]
  [ "$(plan_shown)" -eq 12 ]
  [ "$(box_rows "分类")" -eq 11 ]
  # 切到只有 1 个功能的分类：双栏高度回到 分类数 + 2
  _DASH_SEL=(); _DASH_PANE=0
  ui_dashboard_handle_key UP
  ui_dashboard_compose
  frame_fits
  [ "$(box_rows "分类")" -eq $(( ${#_DASH_CAT_NAME[@]} + 2 )) ]
}

@test "分配: 100x28 双栏 + 12 条预演全部可见且不超过 28 行；30 条时压到下限并提示另有" {
  _dash_layout_set 100 28
  _DASH_PANE=1; _dash_build_list
  set_plan 12
  ui_dashboard_compose
  frame_fits
  [ "$(plan_shown)" -eq 12 ]
  set_plan 30
  ui_dashboard_compose
  frame_fits
  [ "${#_DASH_FRAME[@]}" -eq 28 ]
  frame_has "另有 [0-9]* 条"
  # 3 个功能仍全部可见
  [ "$(frame_text | grep -c '\[[ ✓]\] ')" -eq 3 ]
}

@test "分配: tiny 模式只输出提示，帧不超过终端行数" {
  _dash_build_list
  set_plan 12
  _dash_layout_set 39 24
  [ "$_DASH_MODE" = "tiny" ]
  ui_dashboard_compose
  [ "${#_DASH_FRAME[@]}" -le 24 ]
  _dash_layout_set 80 2
  ui_dashboard_compose
  [ "${#_DASH_FRAME[@]}" -le 2 ]
}

@test "详情: 说明放得下 2 行，放不下折成 3 行，空列表 1 行" {
  _dash_layout_set 80 24
  _DASH_PANE=1; _dash_build_list
  _dash_detail_need 75
  [ "$_DASH_DN" -eq 2 ]
  use_category n "通知服务" 2
  _DASH_ITEM_DESC["${_DASH_LIST[0]}"]="$(printf '这是一段放不下的说明文字%.0s' {1..8})"
  _dash_detail_need 75
  [ "$_DASH_DN" -eq 3 ]
  _dash_detail_lines 75 3
  [ "${#_DASH_DETAIL[@]}" -eq 3 ]
  local l
  for l in "${_DASH_DETAIL[@]}"; do
    ui_str_width "$(printf '%s' "$l" | sed 's/\x1b\[[0-9;]*m//g')"
    [ "$_UI_W" -eq 75 ]
  done
  [[ "${_DASH_DETAIL[2]}" == *"状态："* ]]
  ui_dashboard_compose
  frame_fits
  _DASH_SEARCH_MODE=2; _DASH_QUERY="不存在的关键词"
  _dash_build_list
  _dash_detail_need 75
  [ "$_DASH_DN" -eq 1 ]
  ui_dashboard_compose
  frame_fits
}

# 把 _dash_flush 的输出应用到虚拟屏幕 SCREEN[]（每段：ESC[行;1H ESC[0m 内容 ESC[0m ESC[K）
screen_apply() {
  local rest seg row content
  rest=$(< "$1")
  while [[ -n "$rest" ]]; do
    seg="${rest%%$'\e[K'*}"; rest="${rest#*$'\e[K'}"
    seg="${seg#$'\e['}"; row="${seg%%;*}"
    content="${seg#*$'1H\e[0m'}"; content="${content%$'\e[0m'}"
    SCREEN[row - 1]="$content"
  done
}
screen_matches_frame() {
  local i
  for (( i = 0; i < _DASH_ROWS; i++ )); do
    if [[ "${SCREEN[i]-}" != "${_DASH_FRAME[i]-}" ]]; then
      echo "第 $(( i + 1 )) 行残留: [${SCREEN[i]-}] ≠ [${_DASH_FRAME[i]-}]" >&2
      return 1
    fi
  done
}

@test "刷新: 框高度变化（预演出现/消失、切换分类、双栏帧变短）后屏幕与新帧逐行一致，无残留" {
  local -a SCREEN=()
  local f="$BATS_TMPDIR/dash-flush.out" step
  use_category n "通知服务" 7
  _DASH_PREV=()
  for step in n24-plain n24-plan n24-cat n24-unsel w40-plan w40-plain w40-cat; do
    case "$step" in
      n24-plain) _dash_layout_set 80 24 ;;
      n24-plan)  set_plan 12 ;;
      n24-cat)   _DASH_PANE=0; ui_dashboard_handle_key UP; _DASH_PANE=1 ;;
      n24-unsel) _DASH_SEL=() ;;
      # 尺寸变化：主循环在 SIGWINCH 后清屏并清空上一帧
      w40-plan)  _dash_layout_set 120 40; SCREEN=(); _DASH_PREV=(); _dash_build_list; set_plan 20 ;;
      w40-plain) _DASH_SEL=() ;;
      w40-cat)   _DASH_PANE=0; ui_dashboard_handle_key DOWN ;;
    esac
    ui_dashboard_compose
    _dash_flush > "$f"
    screen_apply "$f"
    screen_matches_frame
  done
  # 双栏未勾选时帧比屏幕短：帧以下的行必须已擦成空行
  [ "${#_DASH_FRAME[@]}" -lt 40 ]
  [ -z "${SCREEN[39]-}" ]
}

@test "快捷键行: 80x24 必备键位（↑↓ 空格 回车 d q）都在，放不下时省略的是 日志/帮助" {
  _dash_layout_set 80 24
  _DASH_PANE=1
  ui_dashboard_compose
  local last
  last=$(frame_text | tail -n 1)
  [[ "$last" == *"[↑↓] 移动"* && "$last" == *"[空格] 勾选"* && "$last" == *"[回车] 执行"* ]]
  [[ "$last" == *"[d] 预演"* && "$last" == *"[q] 退出"* ]]
  [[ "$last" != *"[l] 日志"* ]]
  ui_str_width "$last"; [ "$_UI_W" -eq 79 ]
  # 60 列：次要键位继续省略，必备键位仍在
  _dash_layout_set 60 24
  ui_dashboard_compose
  last=$(frame_text | tail -n 1)
  [[ "$last" == *"[↑↓] 移动"* && "$last" == *"[空格] 勾选"* && "$last" == *"[回车] 执行"* ]]
  [[ "$last" == *"[d] 预演"* && "$last" == *"[q] 退出"* ]]
  # 40 列：q 退出 始终保留
  _dash_layout_set 40 24
  ui_dashboard_compose
  last=$(frame_text | tail -n 1)
  [[ "$last" == *"[q] 退出"* && "$last" == *"[回车] 执行"* ]]
  ui_str_width "$last"; [ "$_UI_W" -eq 39 ]
  # 宽屏放得下时全部显示
  _dash_layout_set 120 40
  ui_dashboard_compose
  last=$(frame_text | tail -n 1)
  [[ "$last" == *"[l] 日志"* && "$last" == *"[?] 帮助"* && "$last" == *"[q] 退出"* ]]
}

@test "快捷键行: 临时提示占用时不显示键位，按键或 ${DASH_MSG_SECS:-4} 秒后恢复" {
  _dash_layout_set 80 24
  _DASH_PANE=1; _dash_build_list
  _DASH_SEL["${_DASH_LIST[0]}"]=1
  ui_dashboard_handle_key CHAR:d
  [[ "$_DASH_MSG" == "预演已更新"* ]]
  ui_dashboard_compose
  [[ "$(frame_text | tail -n 1)" == *"预演已更新"* ]]
  # 计时：首次见到提示记录时刻，未到期不清
  _dash_msg_expire 100
  _dash_msg_expire 102
  [ -n "$_DASH_MSG" ]
  _dash_msg_expire 104
  [ -z "$_DASH_MSG" ]
  ui_dashboard_compose
  [[ "$(frame_text | tail -n 1)" == *"[q] 退出"* ]]
  # 同一提示再次出现时重新计时；任意按键立即恢复键位
  ui_dashboard_handle_key CHAR:d
  _dash_msg_expire 105
  _dash_msg_expire 108
  [ -n "$_DASH_MSG" ]
  ui_dashboard_handle_key DOWN
  [ -z "$_DASH_MSG" ]
  ui_dashboard_compose
  [[ "$(frame_text | tail -n 1)" == *"[d] 预演"* ]]
}

@test "分配: 开启颜色时 80x24 各行宽度一致，焦点行整行高亮" {
  unset NO_COLOR
  use_category n "通知服务" 4
  _dash_layout_set 80 24
  set_plan 12
  ui_dashboard_compose
  frame_fits
  local l hit=0
  for l in "${_DASH_FRAME[@]}"; do
    if [[ "$l" == *$'\e[44m'* ]]; then
      hit=$(( hit + 1 ))
      # 蓝底从左边框后一直延续到右边框前
      [[ "$l" == *$'│\e[0m\e[44m '* && "$l" == *$'\e[44m \e[0m\e[90m│'* ]]
    fi
  done
  [ "$hit" -eq 1 ]
}
