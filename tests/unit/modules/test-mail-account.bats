#!/usr/bin/env bats
# 测试: modules/mail-account.sh — 配置邮件账户模块 (TC-P1-MOD-002 + TC-P2-CHMOD-002)
# Mock 策略：结构验证 + grep 断言（纯代码结构覆盖）

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"
MODULE_FILE="${DEBNAS_ROOT}/modules/mail-account.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "mail-account: @module 为 mail-account" {
  result=$(parse_meta "module")
  [[ "$result" == "mail-account" ]]
}

@test "mail-account: @name 为 配置邮件账户" {
  result=$(parse_meta "name")
  [[ "$result" == "配置邮件账户" ]]
}

@test "mail-account: @category 为 通知服务" {
  result=$(parse_meta "category")
  [[ "$result" == "通知服务" ]]
}

@test "mail-account: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "mail-account: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

@test "mail-account: @depends 声明 exim4 依赖" {
  result=$(parse_meta "depends")
  [[ "$result" == *"exim4"* ]]
}

# ==================== 语法验证 ====================

@test "mail-account: bash -n 语法通过" {
  run bash -n "$MODULE_FILE"
  [[ "$status" -eq 0 ]]
}

# ==================== 结构验证 ====================

@test "mail-account: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "mail-account: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "mail-account: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "mail-account: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

# ==================== 安全红线 ====================

@test "mail-account: 无 eval 动态命令执行" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" | grep -q '\<eval\>'
}

@test "mail-account: 无 rm -rf / 危险操作" {
  ! grep -q 'rm[[:space:]]\+-rf[[:space:]]\+/' "$MODULE_FILE"
}

# ==================== 函数定义验证 ====================

@test "mail-account: validate_sender_email 函数已定义" {
  grep -q '^validate_sender_email()' "$MODULE_FILE"
}

@test "mail-account: generate_exim_config 函数已定义" {
  grep -q '^generate_exim_config()' "$MODULE_FILE"
}

@test "mail-account: configure_smtp_auth 函数已定义" {
  grep -q '^configure_smtp_auth()' "$MODULE_FILE"
}

@test "mail-account: restart_exim_service 函数已定义" {
  grep -q '^restart_exim_service()' "$MODULE_FILE"
}

@test "mail-account: send_validation_email 函数已定义" {
  grep -q '^send_validation_email()' "$MODULE_FILE"
}

@test "mail-account: 交互输入统一经 _mail_ask（最多 5 次重试）" {
  grep -q '^_mail_ask()' "$MODULE_FILE"
  [[ "$(grep -c '^_mail_ask [a-z_]* ' "$MODULE_FILE")" -eq 3 ]]
}

@test "mail-account: _mail_ask 空值与校验失败重试，用尽后退出" {
  run bash -c '
    set -euo pipefail
    ERROR_GENERAL=7
    log_error() { echo "E:$1"; }
    ui_input() { local v; IFS= read -r v || true; echo "$v"; }
    eval "$(sed -n "/^_mail_ask()/,/^}/p; /^_mail_valid_notify_email()/,/^}/p" "$1"/modules/mail-account.sh)"
    out=""
    _mail_ask out "通知邮箱" "p" "" _mail_valid_notify_email "邮箱格式无效" < <(printf "%s\n" "" bad ok@test.com)
    echo "R:$out"
    printf "\n\n\n\n\n" | _mail_ask out "授权密码" "p" hidden
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 7 ]]
  [[ "$output" == *"E:通知邮箱不能为空"* ]]
  [[ "$output" == *"E:邮箱格式无效"* ]]
  [[ "$output" == *"R:ok@test.com"* ]]
  [[ "$output" == *"E:授权密码输入无效次数过多或输入流已结束"* ]]
}

# ==================== 逻辑验证 ====================

@test "mail-account: SMTP_MAP 声明邮箱到 SMTP 服务器映射" {
  grep -q 'SMTP_MAP=' "$MODULE_FILE"
  grep -q 'qq.com' "$MODULE_FILE"
  grep -q 'gmail.com' "$MODULE_FILE"
}

@test "mail-account: DEBNAS_CRON_MODE 守卫跳过交互" {
  grep -q 'DEBNAS_CRON_MODE' "$MODULE_FILE"
}

@test "mail-account: 基于系统文件检测已有配置（非 DebNAS 状态标记）" {
  grep -q '/etc/exim4/update-exim4.conf.conf' "$MODULE_FILE"
  grep -q '/etc/email-addresses' "$MODULE_FILE"
  grep -q 'notify_email_get' "$MODULE_FILE"
}

@test "mail-account: 通知邮箱经 notify_email_set 写入（不再直写 /etc/exim4/notify_email）" {
  grep -q 'notify_email_set "\$notify_email"' "$MODULE_FILE"
  ! grep -q 'write_file_if_changed "/etc/exim4/notify_email"' "$MODULE_FILE"
}

@test "mail-account: 调用 check_dependencies 检查 exim4 等依赖" {
  grep -q 'check_dependencies' "$MODULE_FILE"
}

# TC-P2-CHMOD-002: chown root:Debian-exim 权限检查
@test "mail-account: configure_smtp_auth 使用 chown root:Debian-exim (TC-P2-CHMOD-002)" {
  grep -q 'chown root:Debian-exim' "$MODULE_FILE"
}

@test "mail-account: configure_smtp_auth 设置 passwd.client 权限 640" {
  grep -q 'passwd_file="/etc/exim4/passwd.client"' "$MODULE_FILE"
  grep -q 'write_file_if_changed "\$passwd_file".*640' "$MODULE_FILE"
}

@test "mail-account: passwd.client 写入前先收紧为 0640（无 0644 窗口）" {
  grep -A12 '^configure_smtp_auth()' "$MODULE_FILE" | grep -q 'install -m 0640 /dev/null'
  # chmod 必须出现在写入密码之前
  local body
  body=$(sed -n '/^configure_smtp_auth()/,/^}/p' "$MODULE_FILE")
  [[ "$(grep -n 'chmod 640' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'write_file_if_changed "\$passwd_file"' <<<"$body" | cut -d: -f1)" ]]
}

@test "mail-account: dc_smarthost 端口使用 Exim 双冒号写法 host::port" {
  run bash -c '
    set -euo pipefail
    log_warning() { :; }
    eval "$(sed -n "/^to_exim_smarthost()/,/^}/p" "$1"/modules/mail-account.sh)"
    to_exim_smarthost "smtp.qq.com:587"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "smtp.qq.com::587" ]]
  grep -qF "dc_smarthost='\$exim_smarthost'" "$MODULE_FILE"
}

@test "mail-account: 使用 write_file_if_changed 安全写入配置" {
  grep -q 'write_file_if_changed' "$MODULE_FILE"
}

@test "mail-account: 调用 service_ensure 重启 exim4" {
  grep -q 'service_ensure.*exim4' "$MODULE_FILE"
}

@test "mail-account: send_validation_email 通过 exim4 发送测试邮件" {
  grep -A50 'send_validation_email()' "$MODULE_FILE" | grep -q 'exim4 -oi -bm'
}

@test "mail-account: 通知邮箱格式正则验证" {
  grep -q 'notify_email.*=~' "$MODULE_FILE"
}

# ==================== TC-P1-IMOD-001: SMTP 管道交互测试 ====================

@test "mail-account: validate_sender_email qq.com 返回 smtp.qq.com:587 (TC-P1-IMOD-001)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }

    # 提取 SMTP_MAP + validate_sender_email（按定义边界匹配，不依赖行号）
    eval "$(sed -n "/^declare -A SMTP_MAP=(/,/^)/p; /^validate_sender_email()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    validate_sender_email "test@qq.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "smtp.qq.com:587" ]]
}

@test "mail-account: validate_sender_email gmail.com 返回 smtp.gmail.com:587 (TC-P1-IMOD-001)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }

    eval "$(sed -n "/^declare -A SMTP_MAP=(/,/^)/p; /^validate_sender_email()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    validate_sender_email "user@gmail.com"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "smtp.gmail.com:587" ]]
}

@test "mail-account: validate_sender_email 不支持域名返回 1 (TC-P1-IMOD-001)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }

    eval "$(sed -n "/^declare -A SMTP_MAP=(/,/^)/p; /^validate_sender_email()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    validate_sender_email "test@unknown-domain.xyz"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
}

@test "mail-account: validate_sender_email 空字符串返回 1 (TC-P1-IMOD-001)" {
  run bash -c '
    set -euo pipefail
    SRC="$1"

    log_info() { :; }; log_error() { :; }; log_success() { :; }
    log_warning() { :; }; log_fail() { :; }

    eval "$(sed -n "/^declare -A SMTP_MAP=(/,/^)/p; /^validate_sender_email()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    validate_sender_email ""
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 1 ]]
}

@test "mail-account: send_validation_email 管道内容通过 exim4 -bm 发送 (TC-P1-IMOD-001)" {
  local mock_bin
  mock_bin=$(mktemp -d)

  # Mock exim4: 记录 stdin 内容，输出确认消息
  cat > "$mock_bin/exim4" << 'MOCKEOF'
#!/usr/bin/env bash
# 记录通过管道传入的邮件内容
while IFS= read -r line; do
  echo "$line"
done
echo "EXIM_OK"
MOCKEOF
  chmod +x "$mock_bin/exim4"

  run bash -c '
    set -euo pipefail
    SRC="$1" MOCK_BIN="$2"

    log_info() { :; }; log_error() { :; }; log_success() { echo "SUCCESS"; }
    log_warning() { :; }; log_fail() { echo "FAIL:$*"; exit 1; }
    service_ensure() { return 0; }
    _get_os_id() { echo debian; }
    _get_os_version_id() { echo 12; }
    get_system_codename() { echo bookworm; }

    export PATH="$MOCK_BIN:$PATH"

    eval "$(sed -n "/^_mail_mime_subject()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    eval "$(sed -n "/^send_validation_email()/,/^}/p" "$SRC"/modules/mail-account.sh)"
    send_validation_email "notify@test.com" "sender@qq.com" "smtp.qq.com:587"
  ' _ "${DEBNAS_ROOT}" "$mock_bin"

  rm -rf "$mock_bin"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"EXIM_OK"* ]]
  [[ "$output" == *"Subject:"* ]]
  [[ "$output" == *"DebNAS"* ]]
  [[ "$output" == *"系统版本: Debian 12 (bookworm)"* ]]
}

@test "mail-account: [D3] 测试邮件主题 RFC 2047 编码、带 MIME 头，exim4 加 -oi" {
  local d="${BATS_TEST_TMPDIR}/ma-d3"
  mkdir -p "$d"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/args"\ncat > "%s/mail"\n' "$d" "$d" > "$d/exim4"
  chmod +x "$d/exim4"
  run bash -c '
    set -euo pipefail
    log_info() { :; }; log_error() { :; }; log_success() { :; }
    _get_os_id() { echo debian; }; _get_os_version_id() { echo 12; }; get_system_codename() { echo bookworm; }
    export PATH="$2:$PATH"
    eval "$(sed -n "/^_mail_mime_subject()/,/^}/p" "$1")"
    eval "$(sed -n "/^send_validation_email()/,/^}/p" "$1")"
    send_validation_email "notify@test.com" "sender@qq.com" "smtp.qq.com:587"
  ' _ "$MODULE_FILE" "$d"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$d/args")" == "-oi -bm notify@test.com" ]]
  grep -qx 'MIME-Version: 1.0' "$d/mail"
  grep -qx 'Content-Type: text/plain; charset=UTF-8' "$d/mail"
  local subj w decoded=""
  subj=$(awk '/^Subject: /{s=substr($0,10); f=1; next} f && /^ /{s=s $0; next} {f=0} END{print s}' "$d/mail")
  ! LC_ALL=C grep -q '[^ -~]' <<< "$subj"
  for w in $subj; do
    [[ "${#w}" -le 75 ]]
    w="${w#=?UTF-8?B?}"; w="${w%?=}"
    decoded+=$(printf '%s' "$w" | base64 -d)
  done
  [[ "$decoded" == "来自 [DebNAS] 的测试邮件" ]]
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块：只得到函数定义，不执行 main；普通用户可运行

PROBE_FILE="${DEBNAS_ROOT}/modules/mail-account.sh"

# 加载模块后调用契约函数（stderr 单独丢弃，保证 stdout 只有契约行）
_probe_call() {
  local action="$1"
  DEBNAS_MODULE_ACTION="$action" DEBNAS_STATE_DIR="${BATS_TMPDIR}/mail-account-probe-state" \
    DEBNAS_FEATURE_DIR="${BATS_TMPDIR}/mail-account-probe-state" \
    bash -c 'source "$1" </dev/null >/dev/null 2>&1 || exit 3; module_"$2"' _ "$PROBE_FILE" "$action" 2>/dev/null </dev/null
}

@test "mail-account-contract: 末行为契约守卫" {
  [[ "$(tail -n 1 "$PROBE_FILE")" == 'if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi' ]]
}

@test "mail-account-contract: 不再有无守卫的顶层 main 调用" {
  ! grep -qxF 'main "$@"' "$PROBE_FILE"
}

@test "mail-account-contract: module_status / module_plan 已定义" {
  grep -q '^module_status()' "$PROBE_FILE"
  grep -q '^module_plan()' "$PROBE_FILE"
}

@test "mail-account-contract: 探测加载不执行 main（加载阶段无任何输出）" {
  run env DEBNAS_MODULE_ACTION=status DEBNAS_STATE_DIR="${BATS_TMPDIR}/mail-account-probe-state" \
    bash -c 'source "$1" </dev/null 2>&1; echo SOURCED_OK' _ "$PROBE_FILE"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "SOURCED_OK" ]]
}

@test "mail-account-contract: module_status 输出一行且状态码合法" {
  run _probe_call status
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\|.+ ]]
}

@test "mail-account-contract: module_plan 每行类型合法且为三段" {
  run _probe_call plan
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -ge 1 ]]
  local line
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(pkg|write|service|port|cron|user|risk|info)\|[^|]*\|.* ]] || { echo "非法行：$line"; return 1; }
  done
}

@test "mail-account-contract: module-runner --probe status 返回合法一行" {
  run env DEBNAS_STATE_DIR="${BATS_TMPDIR}/mail-account-probe-state" bash "${DEBNAS_ROOT}/bin/module-runner.sh" --probe status mail-account
  [[ "$status" -eq 0 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" =~ ^(applied|running|partial|absent|warn|error|unknown)\| ]]
  [[ "${lines[0]}" != "unknown|未提供状态检测" ]]
}
