#!/usr/bin/env bats
# 测试: modules/security.sh — 配置安全加固模块 (F-30~F-31)
# Mock 策略：结构验证 + grep 断言（不 Mock 真实 /etc/pam.d/su，纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/security.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "security: @module 为 security" {
  result=$(parse_meta "module")
  [[ "$result" == "security" ]]
}

@test "security: @name 已声明" {
  result=$(parse_meta "name")
  [[ -n "$result" ]]
}

@test "security: @category 已声明" {
  result=$(parse_meta "category")
  [[ -n "$result" ]]
}

@test "security: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "security: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 语法验证 ====================

@test "security: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "security: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "security: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "security: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "security: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全逻辑验证 ====================

@test "security: configure_su_restrictions 函数引用 pam_wheel" {
  grep -A20 '^configure_su_restrictions()' "$MODULE_FILE" | grep -q 'pam_wheel'
}

@test "security: configure_su_restrictions 使用 write_file_if_changed 安全写入" {
  grep -A80 '^configure_su_restrictions()' "$MODULE_FILE" | grep -q 'write_file_if_changed'
}

@test "security: configure_timeout_and_logging 函数包含 TMOUT=900" {
  # TMOUT=900 在 profile_addition 变量体中（函数 ~32 行处），直接 grep 全文
  grep -q 'TMOUT=900' "$MODULE_FILE"
}

@test "security: configure_timeout_and_logging 包含安全审计配置 marker" {
  grep -q '# DebNAS 安全审计配置' "$MODULE_FILE"
}

@test "security: configure_timeout_and_logging 创建 /var/log/history 目录" {
  grep -A30 '^configure_timeout_and_logging()' "$MODULE_FILE" | grep -q '/var/log/history'
}

@test "security: 存在 REQUIRED_CMDS 依赖检查" {
  grep -q 'REQUIRED_CMDS=' "$MODULE_FILE"
}

@test "security: 调用 check_dependencies 检查必备命令" {
  grep -q 'check_dependencies' "$MODULE_FILE"
}

@test "security: configure_timeout_and_logging 使用 write_file_if_changed 写入 /etc/profile" {
  # 函数体较长（~60 行），需要足够的上下文行数
  grep -A60 '^configure_timeout_and_logging()' "$MODULE_FILE" | grep -q 'write_file_if_changed.*/etc/profile'
}

@test "security: main 串联调用 configure_su_restrictions + configure_timeout_and_logging" {
  grep -A5 '^main()' "$MODULE_FILE" | grep -q 'configure_su_restrictions'
  grep -A5 '^main()' "$MODULE_FILE" | grep -q 'configure_timeout_and_logging'
}

# ==================== TC-P1-SEC-001: 功能测试 ====================

@test "security: configure_su_restrictions 幂等 — pam_wheel 已存在时跳过 (TC-P1-SEC-001)" {
  local pam_dir
  pam_dir=$(mktemp -d)
  echo "auth required pam_wheel.so group=sudo" > "$pam_dir/su"

  run bash -c '
    set -euo pipefail
    SRC="$1"
    PAM_DIR="$2"

    # Mock logging functions
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    log_fail() { :; }

    # Mock: cat /etc/pam.d/su → cat 临时文件
    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }

    # Mock: write_file_if_changed — 不应被调用
    write_file_if_changed() { echo "UNEXPECTED_WRITE"; return 1; }

    # 提取并执行函数
    eval "$(sed -n "/^su_restriction_safe_to_apply()/,/^}/p;/^configure_su_restrictions()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_su_restrictions
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"UNEXPECTED_WRITE"* ]]
}

@test "security: configure_su_restrictions 无 pam_wheel 时添加配置 (TC-P1-SEC-001)" {
  local pam_dir
  pam_dir=$(mktemp -d)
  # Debian 默认 /etc/pam.d/su：pam_rootok 生效、pam_wheel 仅有注释示例 → 视为未配置
  printf '%s\n' \
    'auth       sufficient pam_rootok.so' \
    '# auth       required   pam_wheel.so' \
    '# auth       sufficient pam_wheel.so trust' \
    '@include common-auth' > "$pam_dir/su"

  run bash -c '
    set -euo pipefail
    SRC="$1"
    PAM_DIR="$2"

    write_called=0
    write_content=""
    SUDO_USER="admin"
    id() { echo "admin sudo"; }

    # Mock logging
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    log_fail() { :; }

    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }

    write_file_if_changed() {
      write_called=1
      write_content="$2"
      return 0
    }

    eval "$(sed -n "/^su_restriction_safe_to_apply()/,/^}/p;/^configure_su_restrictions()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_su_restrictions

    echo "WRITE_CALLED=$write_called"
    echo "CONTENT=$write_content"
    # 规则必须紧跟 pam_rootok（第 2 行），否则 root 自身也无法 su
    echo "LINE2=$(sed -n 2p <<< "$write_content")"
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"WRITE_CALLED=1"* ]]
  [[ "$output" == *"pam_wheel.so group=sudo"* ]]
  [[ "$output" == *"LINE2=auth       required   pam_wheel.so group=sudo use_uid"* ]]
}

@test "security: configure_su_restrictions 管理员不在 sudo 组时跳过，避免锁死" {
  local pam_dir
  pam_dir=$(mktemp -d)
  printf '%s\n' 'auth       sufficient pam_rootok.so' '@include common-auth' > "$pam_dir/su"

  run bash -c '
    set -euo pipefail
    SRC="$1"
    PAM_DIR="$2"
    SUDO_USER="admin"
    id() { echo "admin users"; }
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }
    write_file_if_changed() { echo "UNEXPECTED_WRITE"; return 0; }
    eval "$(sed -n "/^su_restriction_safe_to_apply()/,/^}/p;/^configure_su_restrictions()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_su_restrictions
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"UNEXPECTED_WRITE"* ]]
}

# ==================== TC-P2-CHMOD-001: chmod 1733 验证 ====================

@test "security: configure_timeout_and_logging 使用 chmod 1733 (TC-P2-CHMOD-001)" {
  local mock_bin prof_dir chmod_log
  mock_bin=$(mktemp -d)
  prof_dir=$(mktemp -d)
  chmod_log=$(mktemp)

  # PATH Injection: chmod → 记录参数
  cat > "$mock_bin/chmod" << INNEREOF
#!/usr/bin/env bash
echo "CHMOD_ARGS=\$*" >> "$chmod_log"
exit 0
INNEREOF
  chmod +x "$mock_bin/chmod"

  # stat mock: return non-1733 to trigger chmod
  cat > "$mock_bin/stat" << 'INNEREOF'
#!/usr/bin/env bash
echo "755"
exit 0
INNEREOF
  chmod +x "$mock_bin/stat"

  touch "$prof_dir/profile"  # 空 profile

  run bash -c '
    set -euo pipefail
    SRC="$1" MOCK_BIN="$2" PROF_DIR="$3" CHMOD_LOG="$4"

    # Mock logging
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    log_fail() { :; }

    cat() {
      if [[ "$1" == "/etc/profile" ]]; then
        command cat "$PROF_DIR/profile"
      else
        command cat "$@"
      fi
    }

    write_file_if_changed() { return 0; }
    mkdir() { return 0; }
    chown() { return 0; }

    export PATH="$MOCK_BIN:$PATH"

    eval "$(sed -n "/^_SECURITY_PROFILE_MARKER=/,/^export HISTFILE=/p;/^configure_timeout_and_logging()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_timeout_and_logging

    cat "$CHMOD_LOG" 2>/dev/null || echo "NO_CHMOD_CALL"
  ' _ "${DEBNAS_ROOT}" "$mock_bin" "$prof_dir" "$chmod_log"

  rm -rf "$mock_bin" "$prof_dir" "$chmod_log"
  [[ "$output" == *"1733"* ]]
}

@test "security: configure_timeout_and_logging 审计标记已存在时跳过写入" {
  local prof_dir
  prof_dir=$(mktemp -d)
  echo "# DebNAS 安全审计配置" > "$prof_dir/profile"

  run bash -c '
    set -euo pipefail
    SRC="$1" PROF_DIR="$2"

    write_called=0

    # Mock logging
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    log_fail() { :; }

    cat() {
      if [[ "$1" == "/etc/profile" ]]; then
        command cat "$PROF_DIR/profile"
      else
        command cat "$@"
      fi
    }

    stat() { echo "1733"; }
    write_file_if_changed() { write_called=1; return 0; }
    mkdir() { return 0; }
    chmod() { return 0; }
    chown() { return 0; }

    eval "$(sed -n "/^_SECURITY_PROFILE_MARKER=/,/^export HISTFILE=/p;/^configure_timeout_and_logging()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_timeout_and_logging

    echo "WRITE_CALLED=$write_called"
  ' _ "${DEBNAS_ROOT}" "$prof_dir"

  rm -rf "$prof_dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"WRITE_CALLED=0"* ]]
}

# ==================== TC-P1-SEC-002: corrupted PAM 文件错误处理 ====================

@test "security: PAM 文件含 NUL 字节时拒绝写入并报错 (TC-P1-SEC-002)" {
  local pam_dir
  pam_dir=$(mktemp -d)
  # 模拟损坏的 PAM 文件：包含 NUL 字节
  printf 'auth\x00broken\n!!!INVALID_PAM_CONTENT!!!' > "$pam_dir/su"

  run bash -c '
    set -euo pipefail
    SRC="$1" PAM_DIR="$2"

    write_called=0
    error_logged=0

    # Mock logging
    log_info() { :; }
    log_success() { :; }
    log_error() { [[ "$*" == *"已损坏"* ]] && error_logged=1; }
    log_warning() { :; }
    log_fail() { :; }

    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }

    # Mock od：本测试只用于 NUL 检测，直接报告 00 字节
    od() {
      printf " 00\n"
    }

    write_file_if_changed() {
      write_called=1
      return 0
    }

    eval "$(sed -n "/^su_restriction_safe_to_apply()/,/^}/p;/^configure_su_restrictions()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_su_restrictions || true

    echo "WRITE_CALLED=$write_called"
    echo "ERROR_LOGGED=$error_logged"
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
  # Phase 9B 修复后：检测到 NUL 字节 → log_error + return 1，拒绝写入
  [[ "$output" == *"WRITE_CALLED=0"* ]]
  [[ "$output" == *"ERROR_LOGGED=1"* ]]
}

@test "security: PAM 文件为空（无 pam_rootok）时不写入，避免锁死 root (TC-P1-SEC-002)" {
  local pam_dir
  pam_dir=$(mktemp -d)
  touch "$pam_dir/su"  # 空文件 → 等同于文件不存在

  run bash -c '
    set -euo pipefail
    SRC="$1" PAM_DIR="$2"

    write_called=0
    write_content=""

    # Mock logging
    log_info() { :; }
    log_success() { :; }
    log_error() { :; }
    log_warning() { :; }
    log_fail() { :; }

    cat() {
      if [[ "$1" == "/etc/pam.d/su" ]]; then
        command cat "$PAM_DIR/su"
      else
        command cat "$@"
      fi
    }

    write_file_if_changed() {
      write_called=1
      write_content="$2"
      return 0
    }

    eval "$(sed -n "/^su_restriction_safe_to_apply()/,/^}/p;/^configure_su_restrictions()/,/^}/p" "$SRC"/modules/security.sh)"
    configure_su_restrictions

    echo "WRITE_CALLED=$write_called"
  ' _ "${DEBNAS_ROOT}" "$pam_dir"

  rm -rf "$pam_dir"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"WRITE_CALLED=0"* ]]
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 探测方式与 lib/system/module-probe.sh 一致：预加载库 + _DEBNAS_BOOTSTRAPPED=1 + DEBNAS_MODULE_ACTION=status|plan 后 source。
# source 期间把常见"执行动作"类函数替换为写标记文件，用于断言探测时 main 未执行。

# 参数：$1 — status|plan|eval，$2 — 标记文件，$3 — eval 时在 source 后执行的脚本片段
_contract_probe() {
  local action="$1" marker="$2" snippet="${3:-}"
  local probe_action="$action"
  [[ "$action" == "eval" ]] && probe_action="status"
  DEBNAS_MODULE_ACTION="$probe_action" _CT_MARKER="$marker" _CT_SNIPPET="$snippet" \
    bash -c '
      set -euo pipefail
      source "$1/lib/bootstrap.sh" >/dev/null 2>&1 || exit 90
      _DEBNAS_BOOTSTRAPPED=1
      _CT_SOURCING=1
      _ct_mark() { [[ -n "${_CT_SOURCING:-}" ]] && echo "$1" >> "$_CT_MARKER"; return 0; }
      log_info() { _ct_mark log_info; }
      log_success() { _ct_mark log_success; }
      log_warning() { _ct_mark log_warning; }
      log_error() { _ct_mark log_error; }
      ui_progress_step() { _ct_mark ui_progress_step; }
      ui_menu() { _ct_mark ui_menu; return 255; }
      register_temp_cleanup() { _ct_mark register_temp_cleanup; }
      create_temp_file() { _ct_mark create_temp_file; echo /dev/null; }
      check_dependencies() { _ct_mark check_dependencies; return 0; }
      apt_install_packages() { _ct_mark apt_install_packages; return 0; }
      service_ensure() { _ct_mark service_ensure; return 0; }
      write_file_if_changed() { _ct_mark write_file_if_changed; return 1; }
      source "$2" </dev/null >/dev/null 2>&1 || exit 91
      unset _CT_SOURCING
      case "$DEBNAS_MODULE_ACTION" in
        status) if [[ -n "$_CT_SNIPPET" ]]; then source /dev/stdin <<< "$_CT_SNIPPET"; else module_status; fi ;;
        plan) module_plan ;;
      esac
    ' _ "$DEBNAS_ROOT" "$MODULE_FILE" </dev/null 2>/dev/null
}

_contract_status_ok() {
  [[ "$(printf '%s\n' "$1" | grep -c .)" -eq 1 ]] || return 1
  [[ "$1" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+$ ]]
}

_contract_plan_ok() {
  local line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.*$ ]] || return 1
    n=$((n + 1))
  done <<< "$1"
  [[ $n -gt 0 ]]
}

@test "security: 契约守卫行原样存在且为最后一行，无裸 main 调用" {
  grep -qxF 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' "$MODULE_FILE"
  [[ "$(tail -n 1 "$MODULE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
  ! grep -qx 'main "\$@"' "$MODULE_FILE"
}

@test "security: 定义 module_status / module_plan" {
  grep -q '^module_status()' "$MODULE_FILE"
  grep -q '^module_plan()' "$MODULE_FILE"
}

@test "security: module_status 输出一行且状态码合法" {
  local marker="$BATS_TMPDIR/ct-security-status.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
}

@test "security: module_plan 每行类型合法（类型|目标|备注）" {
  local marker="$BATS_TMPDIR/ct-security-plan.mark"
  rm -f "$marker"
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
}

@test "security: 探测加载不执行 main（source 期间无动作函数调用）" {
  local marker="$BATS_TMPDIR/ct-security-main.mark"
  rm -f "$marker"
  run _contract_probe status "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  run _contract_probe plan "$marker"
  [[ "$status" -eq 0 ]]
  [[ ! -s "$marker" ]]
  rm -f "$marker"
}

@test "security: module-runner --probe status/plan 正常返回" {
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status security
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" != "unknown|未提供状态检测" ]]
  run bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe plan security
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" != *"未提供预演"* ]]
}

@test "security: 依赖检查移入 main（顶层无 check_dependencies/exit）" {
  if grep -q '^if ! check_dependencies' "$MODULE_FILE"; then false; fi
  grep -A6 '^main()' "$MODULE_FILE" | grep -q 'check_dependencies'
}

@test "security: su 限制判据读取 /etc/pam.d/su 中未注释的 pam_wheel 行" {
  grep -A5 '^_security_su_state()' "$MODULE_FILE" | grep -q "pam_wheel"
  grep -A5 '^_security_su_state()' "$MODULE_FILE" | grep -q '/etc/pam.d/su'
}

@test "security: su 无法读取时 status 降级为 unknown/partial 而非报错" {
  run _contract_probe eval /dev/null '_security_su_state() { return 2; }; module_status'
  [[ "$status" -eq 0 ]]
  _contract_status_ok "$output"
  [[ "$output" == *"需 root 查看"* || "$output" == unknown* ]]
}

@test "security: 管理员不在 sudo 组时 plan 给出跳过 su 限制的风险" {
  run _contract_probe eval /dev/null '
    _security_su_state() { return 1; }
    su_restriction_safe_to_apply() { return 1; }
    cat() { printf "auth sufficient pam_rootok.so\n"; }
    DEBNAS_MODULE_ACTION=plan module_plan'
  [[ "$status" -eq 0 ]]
  _contract_plan_ok "$output"
  [[ "$output" == *"risk|su 限制|当前管理员不在 sudo 组"* ]]
}
