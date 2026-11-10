#!/usr/bin/env bats
# 测试: lib/ui/textwidth.sh — 显示宽度计算 / 截断补齐 / 折行 / 控制字符清理

load '../../helpers/common-setup'

setup() {
  export LC_ALL=C.UTF-8
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/ui/textwidth.sh"
}

@test "ui_str_width: 纯 ASCII 等于字符数" {
  run ui_str_width_echo "DebNAS v3"
  [ "$output" = "9" ]
}

@test "ui_str_width: CJK 每字 2 列" {
  run ui_str_width_echo "安全防护"
  [ "$output" = "8" ]
}

@test "ui_str_width: 中英混排" {
  run ui_str_width_echo "安装 Docker CE"
  [ "$output" = "14" ]
}

@test "ui_str_width: box-drawing 与状态符号占 1 列" {
  run ui_str_width_echo "╭─│●○✓⚠✖…▶┄"
  [ "$output" = "11" ]
}

@test "ui_str_width: ⚡ 按双宽计算" {
  run ui_str_width_echo "⚡ 一键部署"
  [ "$output" = "11" ]
}

@test "ui_str_width: 全角标点占 2 列" {
  run ui_str_width_echo "（：）"
  [ "$output" = "6" ]
}

@test "ui_str_width: 组合附加符占 0 列" {
  run ui_str_width_echo $'é'
  [ "$output" = "1" ]
}

@test "ui_str_width: 空串为 0" {
  run ui_str_width_echo ""
  [ "$output" = "0" ]
}

@test "ui_str_fit: 不足补空格到精确宽度" {
  run ui_str_fit_echo "防火墙" 10
  [ "$output" = "防火墙    " ]
}

@test "ui_str_fit: 右对齐" {
  run ui_str_fit_echo "2/4" 5 right
  [ "$output" = "  2/4" ]
}

@test "ui_str_fit: ASCII 超长截断并以 … 结尾" {
  run ui_str_fit_echo "abcdefghij" 5
  [ "$output" = "abcd…" ]
}

@test "ui_str_fit: 中文截断后宽度精确（不切半个字）" {
  ui_str_fit "安装 Firewalld 防火墙服务" 10
  [ "$_UI_FIT" = "安装 Fire…" ]
  ui_str_width "$_UI_FIT"
  [ "$_UI_W" -eq 10 ]
}

@test "ui_str_fit: 双宽字符跨边界时补空格保证宽度" {
  ui_str_fit "中文中文" 6
  ui_str_width "$_UI_FIT"
  [ "$_UI_W" -eq 6 ]
  [[ "$_UI_FIT" == "中文"* ]]
}

@test "ui_str_fit: 宽度 0 返回空串" {
  run ui_str_fit_echo "abc" 0
  [ "$output" = "" ]
}

@test "ui_str_wrap: 按宽度折行，超出最大行数末行截断" {
  ui_str_wrap "检测到 Docker 已安装：将把 docker0 加入 docker zone，避免容器端口绕过防火墙。" 20 2
  [ "${#_UI_WRAP[@]}" -eq 2 ]
  [[ "${_UI_WRAP[1]}" == *"…" ]]
  local l
  for l in "${_UI_WRAP[@]}"; do ui_str_width "$l"; [ "$_UI_W" -le 20 ]; done
}

@test "ui_str_repeat: 重复多字节字符" {
  ui_str_repeat "─" 4
  [ "$_UI_FIT" = "────" ]
}

@test "ui_str_sanitize: 去除 ESC 等控制字符，Tab 变空格" {
  run ui_str_sanitize $'a\e[31mb\tc\r'
  [ "$output" = "a[31mb c" ]
}

@test "ui_utf8_ensure: C locale 下切换到 UTF-8 语义并可恢复" {
  run bash -c 'export LC_ALL=C; source "$1/lib/ui/textwidth.sh"; ui_utf8_ensure; s="中"; echo "${#s}"; ui_utf8_restore; echo "$LC_ALL"' _ "$DEBNAS_ROOT"
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "C" ]
}
