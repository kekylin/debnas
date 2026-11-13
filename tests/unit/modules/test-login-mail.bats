#!/usr/bin/env bats
# 测试: modules/login-mail/ — 登录邮件通知目录模块
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_DIR="${DEBNAS_ROOT}/modules/login-mail"
MODULE_FILE="${MODULE_DIR}/module.sh"
ACTIONS_FILE="${MODULE_DIR}/actions.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "login-mail: @module 为 login-mail" {
  result=$(parse_meta "module")
  [[ "$result" == "login-mail" ]]
}

@test "login-mail: @name 为 登录邮件通知" {
  result=$(parse_meta "name")
  [[ "$result" == "登录邮件通知" ]]
}

@test "login-mail: @category 为 通知服务" {
  result=$(parse_meta "category")
  [[ "$result" == "通知服务" ]]
}

@test "login-mail: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "login-mail: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "login-mail: @depends 声明 exim4 依赖" {
  result=$(parse_meta "depends")
  [[ "$result" == *"exim4"* ]]
}

@test "login-mail: @depend_modules 声明依赖 mail-account" {
  result=$(parse_meta "depend_modules")
  [[ "$result" == *"mail-account"* ]]
}

# ==================== 语法验证 ====================

@test "login-mail: module.sh bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

@test "login-mail: actions.sh bash -n 语法通过" {
  run bash -n "$ACTIONS_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "login-mail: module.sh 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "login-mail: module.sh 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "login-mail: module.sh main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "login-mail: module.sh 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "login-mail: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$ACTIONS_FILE" | grep -q '\<eval\>'
}

@test "login-mail: actions.sh 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$ACTIONS_FILE"
}

# ==================== 函数定义验证 ====================

@test "login-mail: enable_login_mail 函数已定义" {
  grep -q '^enable_login_mail()' "$ACTIONS_FILE"
}

@test "login-mail: disable_login_mail 函数已定义" {
  grep -q '^disable_login_mail()' "$ACTIONS_FILE"
}

# ==================== 逻辑验证 ====================

@test "login-mail: module.sh 通过 ui_menu 路由到 enable/disable" {
  grep -q 'enable_login_mail' "$MODULE_FILE"
  grep -q 'disable_login_mail' "$MODULE_FILE"
}

@test "login-mail: 登录通知脚本位于 DEBNAS_LOGIN_NOTIFY_SCRIPT（/usr/local/libexec/debnas）" {
  grep -q 'NOTIFY_SCRIPT="\$DEBNAS_LOGIN_NOTIFY_SCRIPT"' "$ACTIONS_FILE"
  ! grep -q 'NOTIFY_SCRIPT="/etc/pam.d/login-notify.sh"' "$ACTIONS_FILE"
}

@test "login-mail: 脚本 750、目录 755" {
  grep -q 'write_file_if_changed "\$NOTIFY_SCRIPT" "\$script_content" 750' "$ACTIONS_FILE"
  grep -q 'chmod 755 -- "\$script_dir"' "$ACTIONS_FILE"
}

@test "login-mail: PAM 行经 login_notify_pam_sync 原位替换（不再 echo >> 追加）" {
  grep -q 'login_notify_pam_sync "\$NOTIFY_SCRIPT"' "$ACTIONS_FILE"
  grep -q 'login_notify_pam_sync ""' "$ACTIONS_FILE"
  ! grep -q '>> "\$PAM_FILE"' "$ACTIONS_FILE"
}

@test "login-mail: 生成的脚本按新旧两个路径读取收件人" {
  grep -q '__DEBNAS_NOTIFY_EMAIL_FILE__' "$ACTIONS_FILE"
  grep -q '__DEBNAS_LEGACY_NOTIFY_EMAIL_FILE__' "$ACTIONS_FILE"
}

@test "login-mail: enable_login_mail 操作 DEBNAS_PAM_SESSION_FILE（/etc/pam.d/common-session）" {
  grep -q 'PAM_FILE="\$DEBNAS_PAM_SESSION_FILE"' "$ACTIONS_FILE"
  grep -q 'DEBNAS_PAM_SESSION_FILE:-/etc/pam.d/common-session' "${DEBNAS_ROOT}/lib/system/layout.sh"
}

@test "login-mail: enable_login_mail 使用 pam_exec.so 集成 PAM（行格式由 layout.sh 生成）" {
  grep -q 'login_notify_pam_sync' "$ACTIONS_FILE"
  grep -q 'session optional pam_exec.so debug seteuid /bin/bash' "${DEBNAS_ROOT}/lib/system/layout.sh"
}

@test "login-mail: 通知脚本 heredoc 包含 exim4 发送逻辑" {
  grep -q '/usr/sbin/exim4' "$ACTIONS_FILE"
}

@test "login-mail: 通知脚本 heredoc 包含 Geo-IP 查询 (ip-api.com)" {
  grep -q 'ip-api.com' "$ACTIONS_FILE"
}

@test "login-mail: Geo-IP 查询默认关闭，需 login_mail_geoip=1 显式启用" {
  grep -q 'login_mail_geoip' "$ACTIONS_FILE"
  grep -q 'GEOIP_ENABLED}" -eq 1 ]] && command -v curl' "$ACTIONS_FILE"
}

@test "login-mail: 通知经 setsid -f 脱离会话后台发送，不阻塞 PAM 登录" {
  grep -q '^  setsid -f /bin/bash "\$0" --send </dev/null >/dev/null 2>&1 || true$' "$ACTIONS_FILE"
}

@test "login-mail: disable_login_mail 移除新旧两种路径的 PAM session 行" {
  grep -A6 '^disable_login_mail()' "$ACTIONS_FILE" | grep -q 'login_notify_pam_sync ""'
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/login-mail/module.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/login-mail-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/login-mail-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "login-mail-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "login-mail-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "login-mail-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "login-mail-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/login-mail-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "login-mail-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "login-mail-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "login-mail-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/login-mail-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status login-mail
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}

# ==================== 审计修复回归（2026-11-10） ====================

# 从 actions.sh 提取生成的 PAM 脚本：填入收件人文件路径，exim4 换成记录参数/正文/会话号的桩
_lm_render_script() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'ops@example.com\n' > "$dir/notify_email"
  cat > "$dir/exim4" <<'M'
#!/bin/bash
d="${BASH_SOURCE[0]%/*}"
printf '%s\n' "$*" > "$d/args.tmp"
ps -o sid= -p $$ | tr -d ' ' > "$d/sid.tmp"
cat > "$d/mail.tmp"
mv "$d/args.tmp" "$d/args"; mv "$d/sid.tmp" "$d/sid"; mv "$d/mail.tmp" "$d/mail"
M
  chmod +x "$dir/exim4"
  sed -n "/IFS= read -r -d '' script_content << 'EOF'/,/^EOF$/p" "$ACTIONS_FILE" | sed '1d;$d' \
    | sed "s#__DEBNAS_NOTIFY_EMAIL_FILE__#$dir/notify_email#g; s#__DEBNAS_LEGACY_NOTIFY_EMAIL_FILE__#$dir/none#g; s#/usr/sbin/exim4#$dir/exim4#g" \
    > "$dir/login-notify.sh"
}

# 运行渲染出的脚本并等待桩 exim4 收到邮件（最多 10 秒）
_lm_run_script() {
  local dir="$1" i
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin PAM_TYPE=open_session PAM_USER=alice PAM_SERVICE=su PAM_TTY=pts/1 \
    PAM_RHOST= /bin/bash "$dir/login-notify.sh" </dev/null >/dev/null 2>&1
  for ((i = 0; i < 100; i++)); do
    [[ -f "$dir/mail" ]] && return 0
    sleep 0.1
  done
  return 1
}

@test "login-mail: [D9] 生成的脚本以 setsid -f 发送，发送进程与 PAM 调用方不在同一会话" {
  command -v setsid >/dev/null 2>&1 || skip "无 setsid"
  local d="${BATS_TEST_TMPDIR}/lm-d9"
  _lm_render_script "$d"
  _lm_run_script "$d"
  local my_sid
  my_sid=$(ps -o sid= -p $$ | tr -d ' ')
  [[ -s "$d/sid" ]]
  [[ "$(cat "$d/sid")" != "$my_sid" ]]
}

@test "login-mail: [D3] 登录通知主题 RFC 2047 编码、带 MIME-Version/UTF-8，exim4 用 -oi -t" {
  local d="${BATS_TEST_TMPDIR}/lm-d3"
  _lm_render_script "$d"
  _lm_run_script "$d"
  [[ "$(cat "$d/args")" == "-oi -t" ]]
  grep -qx 'MIME-Version: 1.0' "$d/mail"
  grep -qx 'Content-Type: text/plain; charset=UTF-8' "$d/mail"
  # 主题头（含折行续写）只含 ASCII，解码后还原原文
  local subj="" line in_subj=0 decoded=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    if [[ "$line" == Subject:* ]]; then in_subj=1; subj+="${line#Subject: }"; continue; fi
    if [[ "$in_subj" -eq 1 && "$line" == " "* ]]; then subj+="$line"; else in_subj=0; fi
  done < "$d/mail"
  if LC_ALL=C grep -q '[^ -~]' <<< "$subj"; then false; fi
  local w
  for w in $subj; do
    [[ "${#w}" -le 75 ]]
    w="${w#=?UTF-8?B?}"; w="${w%?=}"
    decoded+=$(printf '%s' "$w" | base64 -d)
  done
  [[ "$decoded" == "登录通知 · alice @ $(hostname -s)" ]]
}

@test "login-mail: [D1] module_status 对不带 seteuid 的旧格式 PAM 行报 warn" {
  local d="${BATS_TEST_TMPDIR}/lm-d1"
  mkdir -p "$d"
  : > "$d/login-notify.sh"
  printf 'session optional pam_exec.so debug /bin/bash %s\n' "$d/login-notify.sh" > "$d/common-session"
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$d/state" DEBNAS_FEATURE_DIR="$d/state" \
    DEBNAS_LOGIN_NOTIFY_SCRIPT="$d/login-notify.sh" DEBNAS_PAM_SESSION_FILE="$d/common-session" \
    DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT="$d/legacy.sh" DEBNAS_NOTIFY_EMAIL_FILE="$d/notify_email" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_status' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "warn|PAM 行缺少 seteuid"* ]]
  printf 'session optional pam_exec.so debug seteuid /bin/bash %s\n' "$d/login-notify.sh" > "$d/common-session"
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="$d/state" DEBNAS_FEATURE_DIR="$d/state" \
    DEBNAS_LOGIN_NOTIFY_SCRIPT="$d/login-notify.sh" DEBNAS_PAM_SESSION_FILE="$d/common-session" \
    DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT="$d/legacy.sh" DEBNAS_NOTIFY_EMAIL_FILE="$d/notify_email" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_status' _ "$PROBE_FILE"
  [[ "$output" != warn\|PAM\ 行缺少* ]]
}
