#!/usr/bin/env bats
# 测试: modules/sys-patches/ — 检查系统更新目录模块（17 函数，4 文件，3 执行模式）
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/sys-patches"
MODULE_FILE="${MODULE_DIR}/module.sh"
CHECK_FILE="${MODULE_DIR}/check.sh"
NOTIFY_FILE="${MODULE_DIR}/notify.sh"
CRON_FILE="${MODULE_DIR}/cron.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "sys-patches: @module 为 sys-patches" {
  result=$(parse_meta "module")
  [[ "$result" == "sys-patches" ]]
}

@test "sys-patches: @name 为 检查系统更新" {
  result=$(parse_meta "name")
  [[ "$result" == "检查系统更新" ]]
}

@test "sys-patches: @category 为 系统维护" {
  result=$(parse_meta "category")
  [[ "$result" == "系统维护" ]]
}

@test "sys-patches: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "sys-patches: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "sys-patches: @cron 为 true" {
  result=$(parse_meta "cron")
  [[ "$result" == "true" ]]
}

@test "sys-patches: @cron_schedule 为 0 0 * * *" {
  result=$(parse_meta "cron_schedule")
  [[ "$result" == "0 0 * * *" ]]
}

# ==================== 语法验证 ====================

@test "sys-patches: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "sys-patches: check.sh bash -n 语法通过" {
  run bash -n "$CHECK_FILE"
  [[ "$status" -eq 0 ]]
}

@test "sys-patches: notify.sh bash -n 语法通过" {
  run bash -n "$NOTIFY_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "sys-patches: module.sh 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "sys-patches: module.sh 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "sys-patches: module.sh main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "sys-patches: module.sh 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "sys-patches: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$CHECK_FILE" "$NOTIFY_FILE" | grep -q '\<eval\>'
}

@test "sys-patches: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$CHECK_FILE" "$NOTIFY_FILE"
}

# ==================== check.sh 函数验证 ====================

@test "sys-patches: 无调用方的 detect_major_version_update 已删除" {
  ! grep -rq 'detect_major_version_update' "$CHECK_FILE" "$NOTIFY_FILE" "$MODULE_FILE"
}

@test "sys-patches: format_inst_lines 函数已定义" {
  grep -q '^format_inst_lines()' "$CHECK_FILE"
}

@test "sys-patches: build_report_content 函数已定义" {
  grep -q '^build_report_content()' "$CHECK_FILE"
}

@test "sys-patches: run_update_check 函数已定义" {
  grep -q '^run_update_check()' "$CHECK_FILE"
}

@test "sys-patches: execute_update_check 函数已定义" {
  grep -q '^execute_update_check()' "$CHECK_FILE"
}

# ==================== notify.sh 函数验证 ====================


@test "sys-patches: send_email_notification 函数已定义" {
  grep -q '^send_email_notification()' "$NOTIFY_FILE"
}

# ==================== 功能开关验证 ====================

@test "sys-patches: module_enable_feature 函数已定义" {
  grep -q '^module_enable_feature()' "$MODULE_FILE"
}

@test "sys-patches: module_disable_feature 函数已定义" {
  grep -q '^module_disable_feature()' "$MODULE_FILE"
}

# ==================== 逻辑验证 ====================

@test "sys-patches: DEBNAS_CRON_MODE 分派到 run_update_check + send_email" {
  grep -A12 'DEBNAS_CRON_MODE' "$MODULE_FILE" | grep -q 'run_update_check'
  grep -A12 'DEBNAS_CRON_MODE' "$MODULE_FILE" | grep -q 'send_email_notification'
}

@test "sys-patches: DEBNAS_FORCE_YES 分派到 execute_update_check" {
  grep -A12 'DEBNAS_FORCE_YES' "$MODULE_FILE" | grep -q 'execute_update_check'
}

@test "sys-patches: 交互模式调用 main_menu" {
  grep -A3 'else' "$MODULE_FILE" | grep -q 'main_menu'
}

@test "sys-patches: check.sh 使用 apt-get upgrade -s 模拟更新" {
  grep -q 'apt-get upgrade -s' "$CHECK_FILE"
}

@test "sys-patches: check.sh 区分安全更新 (security)" {
  grep -q 'security' "$CHECK_FILE"
}

@test "sys-patches: check.sh 使用 declare -g 声明全局状态变量" {
  grep -q 'declare -g' "$CHECK_FILE"
}

@test "sys-patches: notify.sh 使用 exim4 -oi -t 发送邮件" {
  grep -q '/usr/sbin/exim4 -oi -t' "$NOTIFY_FILE"
}

@test "sys-patches: 收件邮箱读取走 notify_email_get（不直读文件）" {
  sed -n '/^send_email_notification()/,/^}/p' "$NOTIFY_FILE" | grep -q 'notify_email=$(notify_email_get)'
  ! grep -q 'EMAIL_CONFIG_FILE\|/etc/exim4/notify_email' "$MODULE_FILE" "$NOTIFY_FILE" "$CHECK_FILE"
}

@test "sys-patches: 依赖命令为 exim4（不再要求 mailutils 的 mail）" {
  grep -q '^REQUIRED_CMDS=(apt grep awk exim4 systemctl)' "$MODULE_FILE"
}

@test "sys-patches: run_update_check 分类计数（含零更新）" {
  run bash -c '
    set -euo pipefail
    log_info() { :; }; log_warning() { :; }
    apt_update_safe() { return 0; }
    apt-get() { printf "%s\n" "${APT_OUT[@]}"; }
    source "$1"
    APT_OUT=("Reading..." "Inst libc6 [1] (2 Debian-Security:12/stable-security [amd64])" "Inst vim [1] (2 Debian:12/stable [amd64])" "Inst curl [1] (2 Debian:12/stable [amd64])")
    run_update_check
    echo "A:${security_update_count}/${regular_update_count}"
    APT_OUT=("Reading..." "0 upgraded")
    run_update_check
    echo "B:${security_update_count}/${regular_update_count}"
  ' _ "$CHECK_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"A:1/2"* ]]
  [[ "$output" == *"B:0/0"* ]]
}

@test "sys-patches: module_disable_feature 使用 cron_unregister" {
  grep -A5 'module_disable_feature()' "$MODULE_FILE" | grep -q 'cron_unregister'
}

@test "sys-patches: format_inst_lines 使用 awk 格式化输出" {
  grep -A3 'format_inst_lines()' "$CHECK_FILE" | grep -q 'awk'
}

@test "sys-patches: format_inst_lines 不使用 gawk 专有的三参数 match()（兼容 mawk）" {
  ! grep -qE '\<match\(' "$CHECK_FILE"
}

@test "sys-patches: format_inst_lines 正确解析 Inst 行" {
  run bash -c '
    eval "$(sed -n "/^format_inst_lines()/,/^}/p" "$1")"
    printf "%s\n" "Inst libc6 [2.36-9+deb12u7] (2.36-9+deb12u8 Debian-Security:12/stable-security [amd64])" \
      "Inst newpkg (1.0 Debian:12/stable [amd64])" | format_inst_lines
  ' _ "$CHECK_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"libc6"* ]]
  [[ "$output" == *"2.36-9+deb12u7 → 2.36-9+deb12u8"* ]]
  [[ "$output" != *"newpkg"* ]]
}

@test "sys-patches: apt update 失败时标记索引过期并写入报告" {
  grep -q 'apt_index_stale=1' "$CHECK_FILE"
  grep -A20 '^build_report_content()' "$CHECK_FILE" | grep -q 'apt_index_stale'
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/sys-patches/module.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/sys-patches-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/sys-patches-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "sys-patches-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "sys-patches-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "sys-patches-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "sys-patches-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/sys-patches-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "sys-patches-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "sys-patches-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "sys-patches-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/sys-patches-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status sys-patches
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 审计修复回归（2026-11-10，D3） ====================

@test "sys-patches: [D3] 通知邮件主题 RFC 2047 编码、带 MIME-Version，exim4 加 -oi" {
  local d="${BATS_TEST_TMPDIR}/sp-d3"
  mkdir -p "$d"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/args"\ncat > "%s/mail"\n' "$d" "$d" > "$d/exim4"
  chmod +x "$d/exim4"
  run bash -c 'set -euo pipefail; IFS=$'"'"'\n\t'"'"'
    log_info() { :; }; log_warning() { :; }
    notify_email_get() { printf "ops@example.com"; }
    source <(sed "s#/usr/sbin/exim4#$2/exim4#" "$1")
    security_update_count=2 regular_update_count=3 report_content="正文"
    send_email_notification' _ "$NOTIFY_FILE" "$d"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$d/args")" == "-oi -t" ]]
  grep -qx 'MIME-Version: 1.0' "$d/mail"
  grep -qx 'Content-Type: text/plain; charset=UTF-8' "$d/mail"
  local subj w decoded=""
  subj=$(awk '/^Subject: /{s=substr($0,10); f=1; next} f && /^ /{s=s $0; next} {f=0} END{print s}' "$d/mail")
  if LC_ALL=C grep -q '[^ -~]' <<< "$subj"; then false; fi
  for w in $subj; do
    [[ "${#w}" -le 75 ]]
    w="${w#=?UTF-8?B?}"; w="${w%?=}"
    decoded+=$(printf '%s' "$w" | base64 -d)
  done
  [[ "$decoded" == "更新通知 — 发现 5 个可用更新" ]]
}
