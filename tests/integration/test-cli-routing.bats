#!/usr/bin/env bats
# 测试: bin/debnas — CLI 子命令路由与调度 (TC-P0-CLI-001~016)
# Mock 策略: 函数提取 + eval + 子 shell 隔离
# 关键约束: cmd_menu/cmd_install/cmd_doctor 使用 exec，测试用 grep 或子 shell

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
DEBNAS_BIN="${DEBNAS_ROOT}/bin/debnas"

# 提取非-exec 函数（sed 范围提取，所有 cmd_* 函数无嵌套花括号歧义）
extract_function() {
  local func="$1" file="$2"
  sed -n "/^${func}()/,/^}/p" "$file"
}

# ==================== TC-P0-CLI-001: 无子命令 → cmd_menu ====================

@test "CLI: main() 空子命令路由到 cmd_menu (TC-P0-CLI-001)" {
  # grep 验证 case 语句中 "" 分支调用 cmd_menu
  grep -A2 '^[[:space:]]*"")' "$DEBNAS_BIN" | grep -q 'cmd_menu'
}

# ==================== TC-P0-CLI-002~003: cmd_install ====================

@test "CLI: cmd_install 缺少模块名返回 1 (TC-P0-CLI-002)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    # Mock 依赖
    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    discover_modules() { return 0; }
    get_module_list() { echo ""; }
    get_module_field() { echo ""; }

    eval "$(sed -n "/^cmd_install()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_install
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"需要指定模块名"* ]]
}

@test "CLI: cmd_install 通过 exec 调用 module-runner.sh (TC-P0-CLI-003)" {
  # cmd_install() 起始于 line 37，exec 行在 line 56（跨度 19 行），需 -A20
  grep -A20 '^cmd_install()' "$DEBNAS_BIN" | grep -q 'module-runner.sh'
}

# ==================== TC-P0-CLI-004~007: cmd_config ====================

@test "CLI: cmd_config 无参数打印用法 (TC-P0-CLI-004)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo ""; }
    config_write() { return 0; }
    config_delete() { return 0; }

    eval "$(sed -n "/^cmd_config()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_config
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"用法:"* ]]
}

@test "CLI: cmd_config list 列出配置项 (TC-P0-CLI-005)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo "mock"; }
    config_write() { return 0; }
    config_delete() { return 0; }

    eval "$(sed -n "/^cmd_config()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_config list
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"region"* ]]
  [[ "$output" == *"lang"* ]]
  [[ "$output" == *"file_logging"* ]]
}

@test "CLI: cmd_config <key> <value> 调用 config_write (TC-P0-CLI-006)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { echo "SUCCESS"; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo ""; }
    config_write() { echo "WRITE: section=$1 key=$2 value=$3"; }
    config_delete() { return 0; }

    eval "$(sed -n "/^cmd_config()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_config region cn
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"WRITE: section=global key=region value=cn"* ]]
}

@test "CLI: cmd_config <key> --unset 调用 config_delete (TC-P0-CLI-007)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { echo "SUCCESS"; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo ""; }
    config_write() { return 0; }
    config_delete() { echo "DELETE: section=$1 key=$2"; }

    eval "$(sed -n "/^cmd_config()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_config region --unset
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"DELETE: section=global key=region"* ]]
}

# ==================== TC-P0-CLI-008~009: cmd_update ====================

@test "CLI: cmd_update installer_download 失败返回 1 (TC-P0-CLI-008)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo "cn"; }
    mktemp() { echo "/tmp/debnas-update.test"; }
    chmod() { return 0; }
    installer_download() { return 1; }  # 模拟下载失败
    rm() { return 0; }

    eval "$(sed -n "/^cmd_update()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_update
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
}

@test "CLI: cmd_update installer_extract 失败返回 1 (TC-P0-CLI-009)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    config_read() { echo "cn"; }
    mktemp() { echo "/tmp/debnas-update.test"; }
    chmod() { return 0; }
    installer_download() { return 0; }
    installer_extract() { return 1; }   # 模拟解压失败
    rm() { return 0; }

    eval "$(sed -n "/^cmd_update()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_update
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
}

# ==================== TC-P0-CLI-010: cmd_uninstall 交互确认 ====================

@test "CLI: cmd_uninstall 非 FORCE_YES 拒绝取消卸载 (TC-P0-CLI-010)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { echo "LOG_INFO:$*"; }
    log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }

    eval "$(sed -n "/^cmd_uninstall()/,/^}/p" "$SRC"/bin/debnas)"
    DEBNAS_FORCE_YES=0
    # stdin 注入 "n" 表示不确认
    echo "n" | cmd_uninstall
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"已取消卸载"* ]]
}

# ==================== TC-P0-CLI-011~013: cmd_cron ====================

@test "CLI: cmd_cron add 缺少模块名返回 1 (TC-P0-CLI-011)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron add
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"用法"* ]]
}

@test "CLI: cmd_cron remove 缺少模块名返回 1 (TC-P0-CLI-012)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron remove
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"用法"* ]]
}

@test "CLI: cmd_cron enable 缺少模块名返回 1" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron enable
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"用法"* ]]
}

@test "CLI: cmd_cron disable 缺少模块名返回 1" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron disable
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"用法"* ]]
}

@test "CLI: cmd_cron 未知子命令返回 1 (TC-P0-CLI-013)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron unknown_subcommand
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"未知"* ]]
}

@test "CLI: cmd_cron 无参数返回 1" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { echo "ERROR:$*"; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }
    cron_register() { return 0; }
    cron_unregister() { return 0; }
    cron_list() { return 0; }

    eval "$(sed -n "/^cmd_cron()/,/^}/p" "$SRC"/bin/debnas)"
    cmd_cron
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
}

# ==================== TC-P0-CLI-014: main() 未知子命令 ====================

@test "CLI: main() case *) 分支处理未知子命令 (TC-P0-CLI-014)" {
  # main() 含 root 权限检查（EUID readonly 不可 mock），使用结构 grep 验证
  # case *) 分支：log_error "未知子命令: ..." + print_usage + return 1
  grep -A4 '^[[:space:]]*\*)$' "$DEBNAS_BIN" | grep -q '未知子命令'
  grep -A4 '^[[:space:]]*\*)$' "$DEBNAS_BIN" | grep -q 'print_usage'
  grep -A4 '^[[:space:]]*\*)$' "$DEBNAS_BIN" | grep -q 'return 1'
}

# ==================== TC-P0-CLI-015: --cron 参数改写 ====================

@test "CLI: --cron 改写 module --cron → run module (TC-P0-CLI-015)" {
  # parse_global_args 已消费 --cron；main() 在 DEBNAS_CRON_MODE=1 且首参数不是子命令时补 run
  grep -A8 'DEBNAS_CRON_MODE:-0' "$DEBNAS_BIN" | grep -q 'args=(run'
}

# ==================== TC-P0-CLI-016: 全局标志无子命令 ====================

@test "CLI: 全局 CLI 标志无子命令返回 1 (TC-P0-CLI-016)" {
  # main() 含 root 权限检查（EUID readonly 不可 mock），使用结构 grep 验证
  # _DEBNAS_CLI_FLAGS=1 且 subcmd 为空时：log_error + return 1
  grep -A5 '_DEBNAS_CLI_FLAGS' "$DEBNAS_BIN" | grep -q '全局参数需要配合子命令使用'
  grep -A5 '_DEBNAS_CLI_FLAGS' "$DEBNAS_BIN" | grep -q 'return 1'
}

# ==================== 结构验证：所有子命令 case 分支存在 ====================

@test "CLI: main() case 语句包含 install|run 路由" {
  grep -A2 'install|run)' "$DEBNAS_BIN" | grep -q 'cmd_install'
}

@test "CLI: main() case 语句包含 config 路由" {
  grep -A2 '^[[:space:]]*config)$' "$DEBNAS_BIN" | grep -q 'cmd_config'
}

@test "CLI: main() case 语句包含 update 路由" {
  grep -A2 '^[[:space:]]*update)$' "$DEBNAS_BIN" | grep -q 'cmd_update'
}

@test "CLI: main() case 语句包含 uninstall 路由" {
  grep -A2 '^[[:space:]]*uninstall)$' "$DEBNAS_BIN" | grep -q 'cmd_uninstall'
}

@test "CLI: main() case 语句包含 doctor 路由" {
  grep -A2 '^[[:space:]]*doctor)$' "$DEBNAS_BIN" | grep -q 'cmd_doctor'
}

@test "CLI: main() case 语句包含 cron 路由" {
  grep -A2 '^[[:space:]]*cron)$' "$DEBNAS_BIN" | grep -q 'cmd_cron'
}

# ==================== 安全红线 ====================

@test "CLI: bin/debnas 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$DEBNAS_BIN" | grep -q '\<eval\>'
}

# ==================== 根权限检查 ====================

@test "CLI: main() 包含 root 权限检查 (EUID != 0 → exit ERROR_PERMISSION)" {
  grep -A3 'EUID' "$DEBNAS_BIN" | grep -q 'ERROR_PERMISSION'
}

@test "CLI: 安装路径从 layout 常量派生，入口脚本不硬编码" {
  grep -q '^DEBNAS_OPT_DIR=' "${DEBNAS_ROOT}/lib/system/layout.sh"
  grep -q '^DEBNAS_BIN=' "${DEBNAS_ROOT}/lib/system/layout.sh"
  grep -q 'DEBNAS_BIN' "${DEBNAS_ROOT}/bin/debnas"
  grep -q 'DEBNAS_OPT_DIR' "${DEBNAS_ROOT}/bin/menu.sh"
  grep -q 'DEBNAS_BIN' "${DEBNAS_ROOT}/bin/doctor.sh"
  run grep -nE '"/usr/local/bin/debnas"|"/opt/debnas"' \
    "${DEBNAS_ROOT}/bin/debnas" "${DEBNAS_ROOT}/bin/menu.sh" "${DEBNAS_ROOT}/bin/doctor.sh"
  [[ "$status" -ne 0 ]]
}
