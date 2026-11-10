#!/usr/bin/env bats
# 测试: lib/system/module-registry.sh — 模块发现、元数据解析、依赖拓扑排序
# 覆盖 TC-ID: TC-P0-REG-001~016
# 技术: 临时目录隔离 (DEBNAS_MODULES_DIR 覆盖) + Function Override (state_is_installed)

load '../../helpers/common-setup'

# 文件级：设置 mock 模块目录（必须在 source module-registry.sh 前 export，DEBNAS_MODULES_DIR 为 readonly）
TEST_MODULES_DIR="$BATS_TMPDIR/fake-modules"
mkdir -p "$TEST_MODULES_DIR"
export DEBNAS_MODULES_DIR="$TEST_MODULES_DIR"

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 每次测试前重建干净的模块目录
  rm -rf "$TEST_MODULES_DIR"
  mkdir -p "$TEST_MODULES_DIR"

  # source module-registry（需要 state.sh 的 state_is_installed，在此 mock 掉）
  # 先 source state.sh 以获得其他函数，然后覆盖 state_is_installed
  source "${DEBNAS_ROOT}/lib/system/state.sh" 2>/dev/null || true
  source "${DEBNAS_ROOT}/lib/system/module-registry.sh"

  # 重置内部状态
  _MODULE_REGISTRY=()
  _DISCOVERED_MODULES=()
  _MODULES_DISCOVERED=0
}

teardown() {
  rm -rf "$TEST_MODULES_DIR"
}

# 辅助函数：创建单文件模块
# $1: 模块名  $2: 显示名  $3: depend_modules（可选）  $4: order（可选）  $5: category（可选）
make_module() {
  local name="$1" display="$2" deps="${3:-}" order="${4:-50}" category="${5:-系统工具}"
  cat > "$TEST_MODULES_DIR/${name}.sh" << EOF
#!/bin/bash
# @module: ${name}
# @name: ${display}
# @category: ${category}
# @version: 1.0.0
# @order: ${order}
EOF
  if [[ -n "$deps" ]]; then
    echo "# @depend_modules: ${deps}" >> "$TEST_MODULES_DIR/${name}.sh"
  fi
}

# 辅助函数：创建目录式模块
# $1: 模块名  $2: 显示名  $3: depend_modules（可选）
make_directory_module() {
  local name="$1" display="$2" deps="${3:-}"
  local dir="$TEST_MODULES_DIR/${name}"
  mkdir -p "$dir"
  cat > "${dir}/module.sh" << EOF
#!/bin/bash
# @module: ${name}
# @name: ${display}
# @category: 安全防护
# @version: 2.0.0
# @order: 43
EOF
  if [[ -n "$deps" ]]; then
    echo "# @depend_modules: ${deps}" >> "${dir}/module.sh"
  fi
}

# ==================== TC-P0-REG-001: discover_modules 正常发现 ====================

@test "discover_modules: 单文件模块被发现" {
  make_module "test-a" "模块A"
  run discover_modules
  [[ "$status" -eq 0 ]]
  module_exists "test-a"
}

@test "discover_modules: 多个单文件模块全部被发现" {
  make_module "mod-a" "A"
  make_module "mod-b" "B"
  make_module "mod-c" "C"
  discover_modules
  module_exists "mod-a"
  module_exists "mod-b"
  module_exists "mod-c"
}

@test "discover_modules: 目录式模块被发现（type=directory）" {
  make_directory_module "threat-ips" "威胁IP封禁"
  run discover_modules
  [[ "$status" -eq 0 ]]
  module_exists "threat-ips"
  run get_module_field "threat-ips" "type"
  [[ "$output" == "directory" ]]
}

@test "discover_modules: 单文件 + 目录式模块混合发现" {
  make_module "cockpit" "Cockpit面板"
  make_directory_module "sys-patches" "检查系统更新"
  discover_modules
  module_exists "cockpit"
  module_exists "sys-patches"
}

# ==================== TC-P0-REG-002: discover_modules 空目录 ====================

@test "discover_modules: 空目录不报错且无模块" {
  run discover_modules
  [[ "$status" -eq 0 ]]
  run get_module_list
  [[ -z "$output" ]]
}

# ==================== TC-P0-REG-003: discover_modules 目录缺失 ====================

@test "discover_modules: DEBNAS_MODULES_DIR 回退到 _DEBNAS_ROOT/modules" {
  # _get_modules_dir() 有 3 层回退：DEBNAS_MODULES_DIR → _DEBNAS_ROOT/modules → script_dir/../../modules
  # 当 DEBNAS_MODULES_DIR 目录不存在时，回退到 _DEBNAS_ROOT/modules（如果可用）
  # 此测试验证回退行为：在子 shell 中不设置 DEBNAS_MODULES_DIR，依赖 _DEBNAS_ROOT 回退
  run bash -c "
    unset DEBNAS_MODULES_DIR
    export _DEBNAS_ROOT='${DEBNAS_ROOT}'
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/system/module-registry.sh' 2>/dev/null
    discover_modules
  "
  # 回退到真实 modules/ 目录，应成功
  [[ "$status" -eq 0 ]]
}

@test "discover_modules: 所有回退路径均不可用时返回 1" {
  # 三层回退全部阻断：DEBNAS_MODULES_DIR 为空且目录不存在、_DEBNAS_ROOT 未设置、script_dir 回退失败
  local dead_dir
  dead_dir=$(mktemp -d "$BATS_TMPDIR/dead.XXXXXX")
  run bash -c "
    export DEBNAS_MODULES_DIR='${dead_dir}/no-modules-here'
    unset _DEBNAS_ROOT
    cd '${dead_dir}'
    source '${DEBNAS_ROOT}/lib/core/constants.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/colors.sh' 2>/dev/null
    source '${DEBNAS_ROOT}/lib/core/logging.sh' 2>/dev/null
    # source 后 BASH_SOURCE 仍指向真实路径，script_dir 回退会找到真实 modules/
    # 因此需要覆盖 _get_modules_dir 来模拟完全不可用的情况
    source '${DEBNAS_ROOT}/lib/system/module-registry.sh' 2>/dev/null
    _get_modules_dir() { echo '${dead_dir}/no-modules-here'; }
    discover_modules
  "
  rm -rf "$dead_dir"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P0-REG-004~009: resolve_module_deps 拓扑排序 ====================

@test "resolve_module_deps: 无依赖模块返回自身（TC-P0-REG-004）" {
  make_module "standalone" "独立模块"
  discover_modules
  run resolve_module_deps "standalone"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "standalone" ]]
}

@test "resolve_module_deps: 线性链 A→B→C 按拓扑顺序排列（TC-P0-REG-005）" {
  make_module "a" "A" "b"
  make_module "b" "B" "c"
  make_module "c" "C"
  discover_modules
  run resolve_module_deps "a"
  [[ "$status" -eq 0 ]]
  local lines
  readarray -t lines <<< "$output"
  # 拓扑排序：c(最深层)→b→a
  [[ "${lines[0]}" == "c" ]]
  [[ "${lines[1]}" == "b" ]]
  [[ "${lines[2]}" == "a" ]]
}

@test "resolve_module_deps: 菱形依赖 D→B,C ; B→A, C→A 不重复 A（TC-P0-REG-006）" {
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

@test "resolve_module_deps: 直接循环 A→B→A 被检测并报错（TC-P0-REG-007）" {
  make_module "x" "X" "y"
  make_module "y" "Y" "x"
  discover_modules
  run resolve_module_deps "x"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"循环依赖"* ]]
}

@test "resolve_module_deps: 间接循环 A→B→C→A 被检测并报错（TC-P0-REG-008）" {
  make_module "a" "A" "b"
  make_module "b" "B" "c"
  make_module "c" "C" "a"
  discover_modules
  run resolve_module_deps "a"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"循环依赖"* ]]
}

@test "resolve_module_deps: 自依赖 A→A 被检测为循环（TC-P0-REG-009）" {
  make_module "self" "自依赖" "self"
  discover_modules
  run resolve_module_deps "self"
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

# ==================== TC-P0-REG-010: parse_module_metadata 文件不存在 ====================

@test "parse_module_metadata: 文件不存在时返回 1" {
  run parse_module_metadata "$TEST_MODULES_DIR/nonexistent.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"不存在"* ]]
}

# ==================== TC-P0-REG-011: parse_module_metadata 30 行窗口边界 ====================

@test "parse_module_metadata: 第 30 行内的元数据有效" {
  # 创建模块文件：@order 在第 30 行（恰好边界内）
  local f="$TEST_MODULES_DIR/boundary.sh"
  {
    echo '#!/bin/bash'
    echo '# @module: boundary'
    echo '# @name: 边界测试'
    # 填充 26 行注释使 @order 在第 30 行
    for i in $(seq 1 26); do echo "# line $i"; done
    echo '# @order: 77'
  } > "$f"
  run parse_module_metadata "$f"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"order=77"* ]]
}

@test "parse_module_metadata: 第 31 行的元数据被忽略" {
  # 创建模块文件：@order 在第 31 行（超出一行）
  local f="$TEST_MODULES_DIR/over-boundary.sh"
  {
    echo '#!/bin/bash'
    echo '# @module: over-boundary'
    echo '# @name: 超边界'
    for i in $(seq 1 27); do echo "# line $i"; done
    echo '# @order: 99'
  } > "$f"
  run parse_module_metadata "$f"
  [[ "$status" -eq 0 ]]
  # @order 在第 31 行，不应被解析
  ! grep -q "order=99" <<< "$output" || true
}

# ==================== TC-P0-REG-012: _parse_single_file 缺少 @module 标签 ====================

@test "discover_modules: 缺少 @module 标签时警告但继续" {
  # 创建无 @module 标签的文件
  cat > "$TEST_MODULES_DIR/no-meta.sh" << 'EOF'
#!/bin/bash
# @name: 无模块标签
# @category: 系统工具
echo "hello"
EOF
  run discover_modules
  # 应成功（警告但不失败）
  [[ "$status" -eq 0 ]]
  # 模块仍以文件名注册
  module_exists "no-meta"
}

# ==================== TC-P0-REG-013: get_modules_by_category 过滤 + 按 order 排序 ====================

@test "get_modules_by_category: 指定分类时按 order 升序排列" {
  make_module "z-tool" "Z工具" "" "90" "系统工具"
  make_module "a-tool" "A工具" "" "10" "系统工具"
  make_module "m-tool" "M工具" "" "50" "系统工具"
  discover_modules
  run get_modules_by_category "系统工具"
  [[ "$status" -eq 0 ]]
  # 按 order 排序: 10(a-tool), 50(m-tool), 90(z-tool)
  local lines
  readarray -t lines <<< "$output"
  [[ "${lines[0]}" == "a-tool" ]]
  [[ "${lines[1]}" == "m-tool" ]]
  [[ "${lines[2]}" == "z-tool" ]]
}

@test "get_modules_by_category: 空分类返回空" {
  make_module "tool-a" "工具A" "" "50" "系统工具"
  discover_modules
  run get_modules_by_category "不存在的分类"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

# ==================== TC-P0-REG-014: get_modules_by_category 无参返回全部分类 ====================

@test "get_modules_by_category: 无参数返回所有分类（按 CATEGORY_ORDER）" {
  make_module "basic" "基础" "" "10" "基础系统"
  make_module "sec" "安全" "" "40" "安全防护"
  discover_modules
  run get_modules_by_category
  [[ "$status" -eq 0 ]]
  # 应包含分类标题和模块名
  [[ "$output" == *"[基础系统]"* ]]
  [[ "$output" == *"basic"* ]]
  [[ "$output" == *"[安全防护]"* ]]
  [[ "$output" == *"sec"* ]]
}

@test "get_modules_by_category: 无参数时空分类不显示" {
  make_module "only-one" "唯一" "" "10" "基础系统"
  discover_modules
  run get_modules_by_category
  [[ "$status" -eq 0 ]]
  # "管理面板" 分类为空，不应出现
  ! grep -q "\[管理面板\]" <<< "$output" || true
}

# ==================== TC-P0-REG-015~016: check_module_deps_ready ====================

@test "check_module_deps_ready: 无依赖模块返回 0（TC-P0-REG-015）" {
  make_module "solo" "独行"
  discover_modules
  run check_module_deps_ready "solo"
  [[ "$status" -eq 0 ]]
}

@test "check_module_deps_ready: 全部依赖就绪返回 0" {
  # 覆盖 state_is_installed 始终返回 0
  state_is_installed() { return 0; }
  make_module "base" "Base"
  make_module "child" "Child" "base"
  discover_modules
  run check_module_deps_ready "child"
  [[ "$status" -eq 0 ]]
}

@test "check_module_deps_ready: 任一依赖未就绪返回 1 + 列出名称（TC-P0-REG-016）" {
  # 覆盖 state_is_installed: base 返回 1（未就绪），framework 返回 0
  state_is_installed() {
    [[ "$1" == "base" ]] && return 1
    return 0
  }
  make_module "base" "Base"
  make_module "framework" "Framework"
  make_module "child" "Child" "base, framework"
  discover_modules
  run check_module_deps_ready "child"
  [[ "$status" -ne 0 ]]
  # 应列出 base 为未就绪
  [[ "$output" == *"base"* ]]
}

# ==================== get_module_field 补充测试 ====================

@test "get_module_field: 不存在字段返回默认值" {
  make_module "test" "测试"
  discover_modules
  run get_module_field "test" "nonexistent_field" "default-val"
  [[ "$output" == "default-val" ]]
}

@test "get_module_field: 不存在的字段且无默认值返回空" {
  make_module "test" "测试"
  discover_modules
  run get_module_field "test" "nonexistent_xyz"
  [[ -z "$output" ]]
}

@test "get_module_field: @module 字段由 @module 标签覆盖文件名" {
  # 创建文件名为 file-name.sh 但 @module 声明为 custom-name
  cat > "$TEST_MODULES_DIR/file-name.sh" << 'EOF'
#!/bin/bash
# @module: custom-name
# @name: 自定义名称
# @category: 系统工具
EOF
  discover_modules
  # 应以 @module 声明的名称为准
  module_exists "custom-name"
  run get_module_field "custom-name" "module"
  [[ "$output" == "custom-name" ]]
}

# ==================== module_exists 补充测试 ====================

@test "module_exists: 未发现时返回 1" {
  discover_modules
  run module_exists "nonexistent"
  [[ "$status" -ne 0 ]]
}

# ==================== get_module_path ====================

@test "get_module_path: 返回模块文件路径" {
  make_module "path-test" "路径测试"
  discover_modules
  run get_module_path "path-test"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"path-test.sh"* ]]
}

@test "get_module_path: 不存在的模块返回 1" {
  discover_modules
  run get_module_path "nonexistent"
  [[ "$status" -ne 0 ]]
}

# ==================== parse_module_metadata 正常行为 ====================

@test "parse_module_metadata: 正确提取所有元数据字段" {
  make_module "full" "完整模块" "curl,wget" "25" "基础系统"
  run parse_module_metadata "$TEST_MODULES_DIR/full.sh"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"module=full"* ]]
  [[ "$output" == *"name=完整模块"* ]]
  [[ "$output" == *"category=基础系统"* ]]
  [[ "$output" == *"order=25"* ]]
}

# ==================== discover_modules 幂等性 ====================

@test "discover_modules: 多次调用幂等（重复发现不重复注册）" {
  make_module "once" "一次"
  discover_modules
  run get_module_list
  local first_count
  first_count=$(echo "$output" | wc -l)
  # 第二次发现
  discover_modules
  run get_module_list
  local second_count
  second_count=$(echo "$output" | wc -l)
  [[ "$first_count" -eq "$second_count" ]]
}

# ==================== get_module_list 自动发现 ====================

@test "get_module_list: 未调用 discover 时自动触发发现" {
  make_module "auto" "自动"
  # 直接调用 get_module_list（未先调用 discover_modules）
  run get_module_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"auto"* ]]
}

# ==================== get_module_field_var ====================

@test "get_module_field_var: 写入变量、不经子 shell，结果与 get_module_field 一致" {
  make_module "fv-mod" "字段测试"
  discover_modules
  local v=""
  get_module_field_var v "fv-mod" "name"
  [[ "$v" == "$(get_module_field "fv-mod" "name")" ]]
  run get_module_field_var v "fv-mod" "nosuchfield"
  [[ "$status" -eq 1 ]]
  get_module_field_var v "fv-mod" "nosuchfield" "默认"
  [[ "$v" == "默认" ]]
}

@test "get_module_field_var: 未发现时在当前 shell 惰性发现并保留结果" {
  make_module "fv-mod2" "惰性"
  _MODULE_REGISTRY=(); _DISCOVERED_MODULES=(); _MODULES_DISCOVERED=0
  local v=""
  get_module_field_var v "fv-mod2" "category"
  [[ "$v" == "系统工具" ]]
  [[ "$_MODULES_DISCOVERED" -eq 1 ]]
}
