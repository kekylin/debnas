#!/usr/bin/env bats
# 集成测试: modules/sources.sh — 配置 APT 软件源模块
# 验证元数据完整性、语法、结构、Mock 功能

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
export NO_COLOR=1
source "${DEBNAS_ROOT}/lib/core/constants.sh"
source "${DEBNAS_ROOT}/lib/core/colors.sh"
source "${DEBNAS_ROOT}/lib/core/logging.sh"

MODULE_FILE="${DEBNAS_ROOT}/modules/sources.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "sources: @module 为 sources" {
  result=$(parse_meta "module")
  [[ "$result" == "sources" ]]
}

@test "sources: @name 为 配置 APT 软件源" {
  result=$(parse_meta "name")
  [[ "$result" == "配置 APT 软件源" ]]
}

@test "sources: @category 为基础系统" {
  result=$(parse_meta "category")
  [[ "$result" == "基础系统" ]]
}

@test "sources: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "sources: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "sources: @order 为 10（最早执行的基础模块）" {
  result=$(parse_meta "order")
  [[ "$result" == "10" ]]
}

# ==================== 结构验证 ====================
# 注：bash -n 语法检查已由 L1 门禁全局覆盖，此处不再重复

@test "sources: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "sources: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "sources: 定义 DEB822_PATH 常量指向 debian.sources" {
  grep -q 'DEB822_PATH="/etc/apt/sources.list.d/debian.sources"' "$MODULE_FILE"
}

@test "sources: 定义 TRADITIONAL_PATH 常量指向 sources.list" {
  grep -q 'TRADITIONAL_PATH="/etc/apt/sources.list"' "$MODULE_FILE"
}

@test "sources: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "sources: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

@test "sources: probe_mirror 函数存在" {
  grep -q '^probe_mirror()' "$MODULE_FILE"
}

# ==================== Mock 功能验证 ====================

@test "sources: probe_mirror 函数调用 probe_url 并拼接 Release 路径" {
  grep -A3 '^probe_mirror()' "$MODULE_FILE" | grep -q 'probe_url'
  grep -A3 '^probe_mirror()' "$MODULE_FILE" | grep -q 'dists.*Release'
}

@test "sources: detect_best_mirror 含无探测工具时的回退逻辑" {
  grep -q '_HAS_PROBE_TOOL' "$MODULE_FILE"
}

@test "sources: detect_best_mirror 含官方源回退逻辑" {
  grep -q 'APT_OFFICIAL_MIRROR' "$MODULE_FILE"
}

@test "sources: build_deb822_content 生成 DEB822 格式输出" {
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'Types: deb'
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'Signed-By:'
}

@test "sources: DEB822 输出包含安全更新源" {
  sed -n '/^build_deb822_content()/,/^}/p' "$MODULE_FILE" | grep -q 'debian-security'
}

@test "sources: sid 不生成不存在的 -updates/-backports/-security 套件" {
  run bash -c '
    eval "$(sed -n "/^_sources_suite_kind()/,/^}/p;/^build_deb822_content()/,/^}/p" "$1")"
    CODENAME=sid build_deb822_content https://m
  ' _ "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Suites: sid"$'\n'* ]]
  [[ "$output" != *"sid-"* ]]
  [[ "$output" != *"debian-security"* ]]
}

@test "sources: testing 不生成 -backports，保留 -updates/-security" {
  run bash -c '
    eval "$(sed -n "/^_sources_suite_kind()/,/^}/p;/^build_deb822_content()/,/^}/p" "$1")"
    CODENAME=testing build_deb822_content https://m
  ' _ "$MODULE_FILE"
  [[ "$output" == *"Suites: testing testing-updates"$'\n'* ]]
  [[ "$output" != *"backports"* ]]
  [[ "$output" == *"testing-security"* ]]
}

@test "sources: 备份走集中备份 debnas_backup_file，失败/关闭时回退为带时间戳的 .bak" {
  grep -A25 '^_backup_file()' "$MODULE_FILE" | grep -q 'debnas_backup_file "${file}"'
  grep -A25 '^_backup_file()' "$MODULE_FILE" | grep -qF "dest=\"\${file}.\$(printf '%(%Y%m%d%H%M%S)T' -1).bak\""
}

# ==================== 依赖链 ====================

@test "sources: @depend_modules 未声明（无上游依赖）" {
  ! grep -q '@depend_modules:' "$MODULE_FILE"
}
