#!/usr/bin/env bats
# 测试: bin/module-runner.sh — Preflight 执行引擎 (TC-P0-PRE-001~014)
# Mock 策略: 函数提取 + eval + 子 shell 隔离 + 函数覆盖 mock
# 参考: tests/integration/test-cli-routing.bats（同模式）
# 注意: EUID 为 readonly 变量，需要用 preflight_root() { return 0; } 模拟 root 通过

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
MODULE_RUNNER="${DEBNAS_ROOT}/bin/module-runner.sh"

# ==================== TC-P0-PRE-001: dry-run 跳过所有检查 ====================

@test "preflight: run_preflight dry-run 模式跳过检查返回 2 (TC-P0-PRE-001)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { :; }; log_warning() { :; }
    get_module_field() { echo ""; }
    get_module_path() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^preflight_root()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=1
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=2"* ]]
}

# ==================== TC-P0-PRE-002: 非 root 拒绝（mock preflight_root 返回 1） ====================

@test "preflight: run_preflight 非 root 触发 preflight_root 拒绝 (TC-P0-PRE-002)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() { echo ""; }
    get_module_path() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    # EUID 为 readonly，直接 mock preflight_root 返回 1（模拟非 root）
    preflight_root() { log_error "需要 root 权限"; return 1; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
}

# ==================== TC-P0-PRE-003: Debian 版本不匹配 ====================

@test "preflight: run_preflight Debian 版本不匹配返回 1 (TC-P0-PRE-003)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() { echo ""; }
    get_module_path() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 1; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
}

# ==================== TC-P0-PRE-004: 架构不匹配 ====================

@test "preflight: run_preflight 架构不匹配返回 1 (TC-P0-PRE-004)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        arch) echo "arm64" ;;
        debian_min) echo "bookworm" ;;
        interactive) echo "false" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_module_deps_ready() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    verify_architecture_support() { return 1; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
}

# ==================== TC-P0-PRE-004b: @debian_min 主版本号 ====================

@test "preflight: 模块 @debian_min=13 在 Debian 12 上返回 1 (TC-P0-PRE-004b)" {
  run bash -c '
    SRC="$1"
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        debian_min) echo "13" ;;
        interactive) echo "false" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_module_deps_ready() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    verify_architecture_support() { return 0; }
    _get_os_version_id() { echo "12"; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
}

@test "preflight: 模块 @debian_min=13 在 Debian 13 上通过 (TC-P0-PRE-004c)" {
  run bash -c '
    SRC="$1"
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        debian_min) echo "13" ;;
        interactive) echo "false" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_module_deps_ready() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    verify_architecture_support() { return 0; }
    _get_os_version_id() { echo "13"; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

# ==================== TC-P0-PRE-005: 命令依赖缺失 ====================

@test "preflight: run_preflight 命令依赖缺失返回 1 (TC-P0-PRE-005)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        depends) echo "curl wget" ;;
        debian_min) echo "bookworm" ;;
        interactive) echo "false" ;;
        depend_modules) echo "" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_module_deps_ready() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    check_dependencies_by_level() { return 1; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
}

# ==================== TC-P0-PRE-006: 模块依赖未就绪 ====================

@test "preflight: run_preflight 模块依赖未就绪返回 1 + 提示 (TC-P0-PRE-006)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        depends) echo "" ;;
        debian_min) echo "bookworm" ;;
        interactive) echo "false" ;;
        depend_modules) echo "firewall docker-ce" ;;
        name) echo "$1" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_dependencies_by_level() { return 0; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    check_module_deps_ready() { echo "firewall"; echo "docker-ce"; }
    rc=0; run_preflight "test-module" || rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=1"* ]]
  [[ "$output" == *"firewall"* || "$output" == *"docker-ce"* ]]
}

# ==================== TC-P0-PRE-007: 交互模块跳过依赖检查 ====================

@test "preflight: run_preflight 交互模块跳过依赖检查返回 0 (TC-P0-PRE-007)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { :; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        interactive) echo "true" ;;
        debian_min) echo "bookworm" ;;
        arch) echo "" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    rc=1; run_preflight "interactive-module" && rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

# ==================== TC-P0-PRE-008: 全部 5 阶段通过 ====================

@test "preflight: run_preflight 全部阶段通过返回 0 (TC-P0-PRE-008)" {
  run bash -c '
    SRC="$1"
    # 依赖检查由 lib/system/dependency.sh ensure_module_deps 实现（先加载，下方再覆盖 mock）
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { :; }; log_warning() { :; }
    get_module_field() {
      case "$2" in
        depends) echo "curl" ;;
        debian_min) echo "bookworm" ;;
        interactive) echo "false" ;;
        depend_modules) echo "" ;;
        *) echo "" ;;
      esac
    }
    get_module_path() { echo ""; }
    check_dependencies_by_level() { return 0; }
    check_module_deps_ready() { echo ""; }

    eval "$(sed -n "/^preflight_dry_run()/,/^}/p" "$SRC/bin/module-runner.sh")"
    preflight_root() { return 0; }
    eval "$(sed -n "/^preflight_environment_check()/,/^}/p" "$SRC/bin/module-runner.sh")"
    eval "$(sed -n "/^run_preflight()/,/^}/p" "$SRC/bin/module-runner.sh")"

    DEBNAS_DRY_RUN=0
    verify_debian_12_13_support() { return 0; }
    rc=1; run_preflight "test-module" && rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

# ==================== TC-P0-PRE-009: execute_module 子进程 exit 0 ====================

@test "preflight: execute_module 子进程 exit 0 返回 0 (TC-P0-PRE-009)" {
  run bash -c '
    SRC="$1"
    log_info() { :; }; log_action() { :; }; log_error() { :; }
    get_module_field() { echo "Test Module"; }
    get_module_path() { echo "/tmp/mock-module-preflight.sh"; }

    cat > /tmp/mock-module-preflight.sh << "INNEREOF"
#!/bin/bash
exit 0
INNEREOF
    chmod +x /tmp/mock-module-preflight.sh

    eval "$(sed -n "/^execute_module()/,/^}/p" "$SRC/bin/module-runner.sh")"
    rc=1; execute_module "mock-module-preflight" && rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

# ==================== TC-P0-PRE-010: execute_module 子进程 exit 非 0 ====================

@test "preflight: execute_module 子进程 exit 非 0 传播退出码 (TC-P0-PRE-010)" {
  run bash -c '
    SRC="$1"
    log_info() { :; }; log_action() { :; }; log_error() { :; }
    get_module_field() { echo "Failing Module"; }
    get_module_path() { echo "/tmp/mock-fail-module-preflight.sh"; }

    cat > /tmp/mock-fail-module-preflight.sh << "INNEREOF"
#!/bin/bash
exit 42
INNEREOF
    chmod +x /tmp/mock-fail-module-preflight.sh

    eval "$(sed -n "/^execute_module()/,/^}/p" "$SRC/bin/module-runner.sh")"
    rc=0; execute_module "mock-fail-module-preflight" || rc=$?
    # execute_module 透传模块子进程的真实退出码
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=42"* ]]
}

@test "preflight: execute_module 交互式 TTY 不输出 → 日志" {
  run bash -c '
    SRC="$1"
    log_info() { echo "LOG: $*"; }
    get_module_field() { echo "Test Module"; }
    get_module_path() { echo "/tmp/mock-module-preflight.sh"; }

    cat > /tmp/mock-module-preflight.sh << "INNEREOF"
#!/bin/bash
exit 0
INNEREOF
    chmod +x /tmp/mock-module-preflight.sh

    export _DEBNAS_INTERACTIVE_TTY=1
    eval "$(sed -n "/^execute_module()/,/^}/p" "$SRC/bin/module-runner.sh")"
    execute_module "mock-module-preflight"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"LOG:"* ]]
}

# ==================== TC-P0-PRE-011: run_report 成功 ====================

@test "preflight: run_report 成功调用 state_mark_success + SUCCESS (TC-P0-PRE-011)" {
  run bash -c '
    SRC="$1"
    log_success() { echo "SUCCESS: $*"; }
    log_error() { :; }; log_info() { :; }
    log_stop_file() { return 0; }
    get_module_field() { echo "1.0.0"; }
    get_log_file() { echo "/tmp/test.log"; }
    state_mark_success() { echo "STATE_SUCCESS: module=$1 version=$2"; }

    eval "$(sed -n "/^run_report()/,/^}/p" "$SRC/bin/module-runner.sh")"
    run_report "test-module" "Test Module" 0
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"STATE_SUCCESS"* ]]
  [[ "$output" == *"SUCCESS"* ]]
}

@test "preflight: run_report 交互式仅浏览不记录状态 (TC-P0-PRE-011a)" {
  run bash -c '
    SRC="$1"
    log_success() { echo "SUCCESS: $*"; }
    log_error() { :; }; log_info() { :; }
    log_stop_file() { return 0; }
    get_module_field() { echo "1.0.0"; }
    get_log_file() { echo "/tmp/test.log"; }
    state_mark_success() { echo "STATE_SUCCESS: module=$1 version=$2"; }

    export _DEBNAS_INTERACTIVE_TTY=1
    export DEBNAS_ACTION_MARKER=""
    eval "$(sed -n "/^run_report()/,/^}/p" "$SRC/bin/module-runner.sh")"
    run_report "test-module" "Test Module" 0
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"STATE_SUCCESS"* ]]
  [[ "$output" != *"SUCCESS"* ]]
}

@test "preflight: run_report 交互式执行动作后记录状态 (TC-P0-PRE-011b)" {
  run bash -c '
    SRC="$1"
    log_success() { echo "SUCCESS: $*"; }
    log_error() { :; }; log_info() { :; }
    log_stop_file() { return 0; }
    get_module_field() { echo "1.0.0"; }
    get_log_file() { echo "/tmp/test.log"; }
    state_mark_success() { echo "STATE_SUCCESS: module=$1 version=$2"; }

    export _DEBNAS_INTERACTIVE_TTY=1
    MARKER=$(mktemp)
    export DEBNAS_ACTION_MARKER="$MARKER"
    eval "$(sed -n "/^module_mark_action()/,/^}/p" "$SRC/lib/system/state.sh")"
    module_mark_action
    eval "$(sed -n "/^run_report()/,/^}/p" "$SRC/bin/module-runner.sh")"
    run_report "test-module" "Test Module" 0
    rm -f "$MARKER"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"STATE_SUCCESS"* ]]
  [[ "$output" == *"SUCCESS"* ]]
}

@test "preflight: run_report 交互式 mktemp 预建的空标记文件仍视为仅浏览 (TC-P0-PRE-011c)" {
  run bash -c '
    SRC="$1"
    log_success() { echo "SUCCESS: $*"; }
    log_error() { :; }; log_info() { :; }
    log_stop_file() { return 0; }
    get_module_field() { echo "1.0.0"; }
    get_log_file() { echo "/tmp/test.log"; }
    state_mark_success() { echo "STATE_SUCCESS: module=$1 version=$2"; }

    export _DEBNAS_INTERACTIVE_TTY=1
    MARKER=$(mktemp)
    export DEBNAS_ACTION_MARKER="$MARKER"
    eval "$(sed -n "/^run_report()/,/^}/p" "$SRC/bin/module-runner.sh")"
    run_report "test-module" "Test Module" 0
    rm -f "$MARKER"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"STATE_SUCCESS"* ]]
  [[ "$output" != *"SUCCESS"* ]]
}

# ==================== TC-P0-PRE-012: run_report 失败 ====================

@test "preflight: run_report 失败调用 state_mark_fail + ERROR + 日志路径 (TC-P0-PRE-012)" {
  run bash -c '
    SRC="$1"
    log_success() { :; }
    log_error() { echo "ERROR: $*"; }
    log_info() { echo "LOG_INFO: $*"; }
    log_stop_file() { return 0; }
    get_module_field() { echo ""; }
    get_log_file() { echo "/var/log/debnas/test-module-20260101.log"; }
    state_mark_fail() { echo "STATE_FAIL: module=$1 reason=$2"; }

    eval "$(sed -n "/^run_report()/,/^}/p" "$SRC/bin/module-runner.sh")"
    run_report "test-module" "Test Module" 1
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"STATE_FAIL"* ]]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *".log"* ]]
}

# ==================== TC-P0-PRE-013: main() 模块未找到 ====================

@test "preflight: main() 模块未找到列出模块返回 1 (TC-P0-PRE-013)" {
  # main() 含 root 权限检查（EUID readonly），使用结构 grep 验证模块未找到分支
  grep -A8 '! module_exists' "$MODULE_RUNNER" | grep -q '模块不存在'
  grep -A10 '! module_exists' "$MODULE_RUNNER" | grep -q 'get_module_list'
  grep -A10 '! module_exists' "$MODULE_RUNNER" | grep -q 'return 1'
}

# ==================== TC-P0-PRE-014: 完整链路 E2E ====================

@test "preflight: main() 完整链路 preflight→execute→report (E2E 结构验证) (TC-P0-PRE-014)" {
  grep -q 'run_preflight' "$MODULE_RUNNER"
  grep -q 'execute_module' "$MODULE_RUNNER"
  grep -q 'run_report' "$MODULE_RUNNER"
  grep -q 'log_to_file' "$MODULE_RUNNER"
}

# ==================== 依赖命令解析（ensure_module_deps，TC-P1-BND-005） ====================

@test "preflight: ensure_module_deps 空依赖列表返回 0 (TC-P1-BND-005)" {
  run bash -c '
    SRC="$1"
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { :; }
    get_module_field() { echo ""; }
    check_dependencies_by_level() { return 1; }
    rc=1; ensure_module_deps "test-module" && rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

@test "preflight: ensure_module_deps 仅空白字符依赖列表返回 0" {
  run bash -c '
    SRC="$1"
    source "$SRC/lib/system/dependency.sh"
    log_info() { :; }; log_error() { :; }
    get_module_field() { case "$2" in depends) echo "  , , " ;; *) echo "" ;; esac; }
    check_dependencies_by_level() { return 1; }
    rc=1; ensure_module_deps "test-module" && rc=$?
    echo "EXIT=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIT=0"* ]]
}

# ==================== 结构验证：关键函数存在 ====================

@test "preflight: module-runner.sh 包含 preflight_root 函数定义" {
  grep -q '^preflight_root()' "$MODULE_RUNNER"
}

@test "preflight: module-runner.sh 包含 preflight_environment_check 函数定义" {
  grep -q '^preflight_environment_check()' "$MODULE_RUNNER"
}

@test "preflight: run_preflight 经 ensure_module_deps 检查依赖（与交互式模块共用实现）" {
  sed -n '/^run_preflight()/,/^}/p' "$MODULE_RUNNER" | grep -q 'ensure_module_deps "\$module_name"'
}

@test "preflight: module-runner.sh 包含 preflight_dry_run 函数定义" {
  grep -q '^preflight_dry_run()' "$MODULE_RUNNER"
}

@test "preflight: module-runner.sh 包含 run_preflight 函数定义" {
  grep -q '^run_preflight()' "$MODULE_RUNNER"
}

@test "preflight: module-runner.sh 包含 execute_module 函数定义" {
  grep -q '^execute_module()' "$MODULE_RUNNER"
}

@test "preflight: module-runner.sh 包含 run_report 函数定义" {
  grep -q '^run_report()' "$MODULE_RUNNER"
}

# ==================== 安全红线 ====================

@test "preflight: module-runner.sh 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_RUNNER" | grep -q '\<eval\>'
}
