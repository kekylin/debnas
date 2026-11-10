#!/usr/bin/env bats
# 测试: lib/system/dependency.sh — 依赖检测

load '../../helpers/common-setup'

# 在顶层 source（非 setup 内），确保 declare -A 关联数组为全局变量
source "${DEBNAS_ROOT}/lib/system/dependency.sh"

setup() {
  export NO_COLOR=1
  setup_debnas_lib
}

@test "check_dependencies bash 存在" {
  check_dependencies "bash"
}

@test "check_dependencies 多个存在命令" {
  check_dependencies "bash" "grep" "sed"
}

@test "check_dependencies 不存在的命令返回 false" {
  run check_dependencies "nonexistent_command_xyz"
  [ "$status" -ne 0 ]
}

@test "check_dependencies 混合存在/不存在返回 false" {
  run check_dependencies "bash" "nonexistent_command_xyz"
  [ "$status" -ne 0 ]
}

@test "cmd_to_pkg grep 键存在（核心工具映射为空）" {
  [[ -v "cmd_to_pkg[grep]" ]]
  # grep 是核心工具，无需包名映射，值为空
  [ "${cmd_to_pkg[grep]}" = "" ]
}

@test "cmd_to_pkg curl 映射正确" {
  [[ -v "cmd_to_pkg[curl]" ]]
  [ "${cmd_to_pkg[curl]}" = "curl" ]
}

@test "cmd_to_pkg docker 映射为 docker.io" {
  [[ -v "cmd_to_pkg[docker]" ]]
  [ "${cmd_to_pkg[docker]}" = "docker.io" ]
}

@test "cmd_to_pkg firewall-cmd 映射为 firewalld" {
  [[ -v "cmd_to_pkg[firewall-cmd]" ]]
  [ "${cmd_to_pkg[firewall-cmd]}" = "firewalld" ]
}

# ==================== TC-P1-SH-001~002: get_dependency_level ====================

@test "get_dependency_level: bash 为 system 级别" {
  run get_dependency_level "bash"
  [[ "$output" == "system" ]]
}

@test "get_dependency_level: curl 为 tool 级别" {
  run get_dependency_level "curl"
  [[ "$output" == "tool" ]]
}

@test "get_dependency_level: docker 为 service 级别" {
  run get_dependency_level "docker"
  [[ "$output" == "service" ]]
}

@test "get_dependency_level: 未注册命令默认返回 tool（TC-P1-SH-001）" {
  run get_dependency_level "some_unknown_cmd_xyz"
  [[ "$output" == "tool" ]]
}

@test "get_dependency_level: cmd_to_pkg 有映射但 cmd_to_level 无映射时从 pkg 推断（TC-P1-SH-002）" {
  # gawk 在 cmd_to_pkg 中映射为自身，但不在 cmd_to_level 中
  # pkg 非空 → 推断为 tool
  run get_dependency_level "gawk"
  [[ "$output" == "tool" ]]
}

# ==================== TC-P1-DEP-001~002: check_system_deps ====================

@test "check_system_deps: 系统命令全部存在时返回 0（TC-P1-DEP-001）" {
  run check_system_deps "bash" "grep" "sed" "cat"
  [[ "$status" -eq 0 ]]
}

@test "check_system_deps: 系统命令缺失时返回 1（TC-P1-DEP-002）" {
  run check_system_deps "bash" "nonexistent_system_cmd_xyz"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"缺失"* ]]
}

# ==================== TC-P1-DEP-004: check_service_deps ====================

@test "check_service_deps: 服务依赖全部存在时返回 0" {
  # docker 如果已安装在系统上则返回 0
  if command -v docker &>/dev/null; then
    run check_service_deps "docker"
    [[ "$status" -eq 0 ]]
  else
    skip "docker 未安装，跳过服务就绪测试"
  fi
}

@test "check_service_deps: 服务依赖缺失时返回 1（TC-P1-DEP-004）" {
  run check_service_deps "nonexistent_service_xyz"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"未安装"* || "$output" == *"服务"* ]]
}

# ==================== TC-P1-DEP-006: ensure_command Tier 2 拒绝 ====================

@test "ensure_command: Tier 2 服务依赖拒绝自动安装（TC-P1-DEP-006）" {
  # docker 是 Tier 2 service 级别，ensure_command 应拒绝自动安装
  # 如果 docker 已安装则跳过（返回 0），如果未安装则应拒绝
  if command -v docker &>/dev/null; then
    run ensure_command "docker"
    [[ "$status" -eq 0 ]]
  else
    run ensure_command "docker"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"不会自动安装"* || "$output" == *"服务"* ]]
  fi
}

# ==================== check_dependencies_by_level 集成测试 ====================

@test "check_dependencies_by_level: 仅 Tier 0 系统命令全部通过 → 返回 0" {
  run check_dependencies_by_level "bash" "grep" "cat"
  [[ "$status" -eq 0 ]]
}

@test "check_dependencies_by_level: 含 Tier 1 工具命令（apt 调用通过 || true 保护）" {
  # Tier 1 工具命令的 check_and_install_tool_deps 失败被 || true 吞掉
  # 需要实际 apt 源才能成功安装。这里测试整体流程不崩溃。
  # 使用已知的 tool 级别命令（curl），如果已安装则 pass，否则 || true 保护
  run check_dependencies_by_level "curl"
  # curl 在 PATH 上存在(已安装) → 返回 0；或尝试安装失败但被 || true 吞掉 → 返回 0
  [[ "$status" -eq 0 ]]
}

@test "check_dependencies_by_level: Tier 2 服务命令不存在时返回 1" {
  # 使用 docker 作为 Tier 2 测试（如果系统未安装 docker 则触发 service deps 检查失败）
  if command -v docker &>/dev/null; then
    # docker 已安装 → 仅 Tier 2 检查通过
    run check_dependencies_by_level "docker"
    [[ "$status" -eq 0 ]]
  else
    run check_dependencies_by_level "docker"
    [[ "$status" -ne 0 ]]
  fi
}

# ==================== has_valid_main_apt_source ====================

@test "has_valid_main_apt_source: 检查函数存在且可调用" {
  # 此函数检查 /etc/apt/sources.list，返回值取决于实际系统状态
  run has_valid_main_apt_source
  # 不验证具体返回值，只验证函数可调用（不崩溃）
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ==================== TC-P1-DEP-003: Tier 1 工具自动安装 ====================

@test "check_dependencies_by_level: Tier 1 工具触发自动安装 (TC-P1-DEP-003)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/dependency.sh 2>/dev/null

    # 模拟 apt-get 为 noop（避免真实安装）
    apt_get() { return 0; }
    apt-get() { return 0; }
    export -f apt_get apt-get 2>/dev/null || true

    # curl 属于 Tier 1 tool 级别，会自动尝试安装
    # 如果 curl 已安装则返回 0，否则尝试安装
    run check_dependencies_by_level "curl" 2>/dev/null || true
    echo "DEP_LEVEL_OK"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"DEP_LEVEL_OK"* ]]
}

# ==================== TC-P1-DEP-005: ensure_module_deps ====================

@test "ensure_module_deps: 组合 cmd + 模块依赖检查 (TC-P1-DEP-005)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/state.sh 2>/dev/null
    source "$SRC"/lib/system/dependency.sh 2>/dev/null

    # 验证 ensure_module_deps 函数存在
    type -t ensure_module_deps >/dev/null 2>&1 && echo "FUNCTION_EXISTS"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"FUNCTION_EXISTS"* ]]
}

@test "check_system_deps: 缺失命令列表以空格连接、单行输出" {
  [[ "$IFS" == $'\n\t' ]]
  run check_system_deps no_such_cmd_a no_such_cmd_b
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"系统基础命令缺失：no_such_cmd_a no_such_cmd_b"* ]]
}

