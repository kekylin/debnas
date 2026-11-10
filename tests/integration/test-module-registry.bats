#!/usr/bin/env bats
# 集成测试: lib/system/module-registry.sh — 模块发现、元数据解析与依赖排序
# 使用临时模块目录 + mock，不依赖真实 modules/ 目录

# 文件级一次性初始化（BATS 在同一 shell 中运行所有测试）
DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
export NO_COLOR=1
source "${DEBNAS_ROOT}/lib/core/constants.sh"
source "${DEBNAS_ROOT}/lib/core/colors.sh"
source "${DEBNAS_ROOT}/lib/core/logging.sh"

TEST_MODULES_DIR="$BATS_TMPDIR/fake-modules"
mkdir -p "$TEST_MODULES_DIR"
# 必须在 source module-registry.sh 之前设置（声明为 readonly）
export DEBNAS_MODULES_DIR="$TEST_MODULES_DIR"
source "${DEBNAS_ROOT}/lib/system/state.sh"
source "${DEBNAS_ROOT}/lib/system/module-registry.sh"

setup() {
  # 重置内部状态（每个测试独立）
  _MODULE_REGISTRY=()
  _DISCOVERED_MODULES=()
  _MODULES_DISCOVERED=0
}

teardown() {
  rm -rf "$TEST_MODULES_DIR"
}

# 辅助函数：创建单文件模块
make_module() {
  local name="$1" display="$2" deps="${3:-}" order="${4:-50}"
  cat > "$TEST_MODULES_DIR/${name}.sh" << EOF
#!/bin/bash
# @module: ${name}
# @name: ${display}
# @category: 系统工具
# @version: 1.0.0
# @order: ${order}
EOF
  if [[ -n "$deps" ]]; then
    echo "# @depend_modules: ${deps}" >> "$TEST_MODULES_DIR/${name}.sh"
  fi
}

# ==================== 模块发现 ====================

@test "discover_modules: 单文件模块被发现" {
  make_module "test-a" "模块A"
  run discover_modules
  [[ "$status" -eq 0 ]]
  module_exists "test-a"
}

@test "discover_modules: 多个模块被发现" {
  make_module "mod-a" "A"
  make_module "mod-b" "B"
  make_module "mod-c" "C"
  discover_modules
  module_exists "mod-a"
  module_exists "mod-b"
  module_exists "mod-c"
}

@test "discover_modules: 空目录不报错且无模块" {
  run discover_modules
  [[ "$status" -eq 0 ]]
  run get_module_list
  [[ -z "$output" ]]
}

# ==================== 模块列表 ====================

@test "get_module_list: 返回所有已发现模块名" {
  make_module "a" "A"
  make_module "b" "B"
  discover_modules
  run get_module_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"a"* ]]
  [[ "$output" == *"b"* ]]
}

# ==================== 元数据字段读取 ====================

@test "get_module_field: 读取 @name" {
  make_module "test" "测试模块"
  discover_modules
  run get_module_field "test" "name"
  [[ "$output" == "测试模块" ]]
}

@test "get_module_field: 读取 @order" {
  make_module "test" "T" "" "88"
  discover_modules
  run get_module_field "test" "order"
  [[ "$output" == "88" ]]
}

@test "get_module_field: 不存在的字段返回默认值或空" {
  make_module "test" "T"
  discover_modules
  # cron 字段有默认值 "false"，使用不存在的字段名测试回退行为
  run get_module_field "test" "nonexistent_xyz"
  # 不存在且无默认值：输出为空
  [[ -z "$output" ]]
}

# ==================== 依赖拓扑排序 ====================

@test "resolve_module_deps: 无依赖返回自身" {
  make_module "standalone" "独立模块"
  discover_modules
  run resolve_module_deps "standalone"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "standalone" ]]
}

@test "resolve_module_deps: 线性链 A→B→C 按拓扑顺序排列" {
  make_module "a" "A" "b"
  make_module "b" "B" "c"
  make_module "c" "C"
  discover_modules
  run resolve_module_deps "a"
  [[ "$status" -eq 0 ]]
  # 拓扑排序：c(最深层)→b→a
  local lines
  readarray -t lines <<< "$output"
  [[ "${lines[0]}" == "c" ]]
  [[ "${lines[1]}" == "b" ]]
  [[ "${lines[2]}" == "a" ]]
}

@test "resolve_module_deps: 菱形依赖 D→B,C ; B→A, C→A 不重复 A" {
  make_module "a" "A"
  make_module "b" "B" "a"
  make_module "c" "C" "a"
  make_module "d" "D" "b, c"
  discover_modules
  run resolve_module_deps "d"
  [[ "$status" -eq 0 ]]
  # A 只应出现一次
  local count
  count=$(grep -c "^a$" <<< "$output" || true)
  [[ "$count" -eq 1 ]]
}

@test "resolve_module_deps: 循环依赖被检测并报错" {
  make_module "x" "X" "y"
  make_module "y" "Y" "x"
  discover_modules
  run resolve_module_deps "x"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"循环依赖"* ]]
}

@test "resolve_module_deps: 逗号分隔的多依赖被正确解析" {
  make_module "base" "Base"
  make_module "target" "Target" "  base  "
  discover_modules
  run resolve_module_deps "target"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"base"* ]]
}

# ==================== 模块存在性 ====================

@test "module_exists: 已发现模块返回 0" {
  make_module "exists" "存在"
  discover_modules
  module_exists "exists"
}

@test "module_exists: 未知模块返回 1" {
  discover_modules
  run module_exists "nonexistent"
  [[ "$status" -ne 0 ]]
}

# ==================== 分类组织 ====================

@test "get_modules_by_category: 模块按分类正确分组" {
  make_module "tool-a" "工具A"
  discover_modules
  run get_modules_by_category
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"tool-a"* ]]
}

# ==================== 依赖就绪检查 ====================

@test "check_module_deps_ready: 无依赖模块返回 0" {
  make_module "solo" "独行"
  discover_modules
  run check_module_deps_ready "solo"
  [[ "$status" -eq 0 ]]
}

# ==================== 元数据解析（基于文件） ====================

@test "parse_module_metadata: 正确提取 @module 和 @name" {
  make_module "parsed" "解析模块"
  run parse_module_metadata "$TEST_MODULES_DIR/parsed.sh"
  [[ "$output" == *"module=parsed"* ]]
  [[ "$output" == *"name=解析模块"* ]]
}
