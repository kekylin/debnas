#!/usr/bin/env bats
# 测试: lib/system/layout.sh — 通知邮箱新旧路径回退、登录通知 PAM 行同步

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  T="$(mktemp -d "${BATS_TMPDIR}/layout.XXXXXX")"
  export DEBNAS_ETC_DIR="$T/etc/debnas" DEBNAS_VAR_DIR="$T/var/lib/debnas" DEBNAS_LOG_ROOT="$T/var/log/debnas"
  export DEBNAS_BACKUP_ROOT="$T/var/backups/debnas" DEBNAS_LIBEXEC_DIR="$T/libexec/debnas"
  export DEBNAS_LEGACY_NOTIFY_EMAIL_FILE="$T/etc/exim4/notify_email" DEBNAS_GLOBAL_CONF="$T/none"
  export DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT="$T/etc/pam.d/login-notify.sh" DEBNAS_PAM_SESSION_FILE="$T/etc/pam.d/common-session"
  unset DEBNAS_BACKUP_RUN_ID DEBNAS_NOTIFY_EMAIL_FILE DEBNAS_LOGIN_NOTIFY_SCRIPT
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/layout.sh"
  source "${DEBNAS_ROOT}/lib/system/manifest.sh"
  source "${DEBNAS_ROOT}/lib/system/backup.sh"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  mkdir -p "$T/etc/exim4" "$T/etc/pam.d"
  OLD_LINE="session optional pam_exec.so debug /bin/bash $DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"
  # 当前格式带 seteuid；NOEUID_LINE 为上一版写入的新路径行（不带 seteuid，需原位升级）
  NEW_LINE="session optional pam_exec.so debug seteuid /bin/bash $DEBNAS_LOGIN_NOTIFY_SCRIPT"
  NOEUID_LINE="session optional pam_exec.so debug /bin/bash $DEBNAS_LOGIN_NOTIFY_SCRIPT"
}

teardown() {
  [[ -n "${T:-}" ]] && rm -rf -- "$T"
}

@test "layout: 默认路径符合 FHS 收敛方案" {
  run bash -c 'unset DEBNAS_ETC_DIR DEBNAS_LIBEXEC_DIR DEBNAS_BACKUP_ROOT DEBNAS_NOTIFY_EMAIL_FILE DEBNAS_LOGIN_NOTIFY_SCRIPT DEBNAS_LEGACY_NOTIFY_EMAIL_FILE
    source "$1/lib/system/layout.sh"
    echo "$DEBNAS_NOTIFY_EMAIL_FILE|$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE|$DEBNAS_LOGIN_NOTIFY_SCRIPT|$DEBNAS_BACKUP_ROOT"' _ "$DEBNAS_ROOT"
  [[ "$output" == "/etc/debnas/notify_email|/etc/exim4/notify_email|/usr/local/libexec/debnas/login-notify.sh|/var/backups/debnas" ]]
}

@test "notify_email_get: 都不存在返回 1" {
  run notify_email_get
  [[ "$status" -eq 1 ]]
}

@test "notify_email_get: 新路径不存在时回退旧路径（去空白）" {
  echo "  old@example.com " > "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  run notify_email_get
  [[ "$status" -eq 0 ]]
  [[ "$output" == "old@example.com" ]]
}

@test "notify_email_get: 新路径优先；新路径为空视为未配置，不回退" {
  echo "old@example.com" > "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  mkdir -p "$DEBNAS_ETC_DIR"; echo "new@example.com" > "$DEBNAS_NOTIFY_EMAIL_FILE"
  run notify_email_get
  [[ "$output" == "new@example.com" ]]
  : > "$DEBNAS_NOTIFY_EMAIL_FILE"
  run notify_email_get
  [[ "$status" -eq 1 ]]
}

@test "notify_email_set: 写新路径 640，旧普通文件替换为指向新路径的符号链接" {
  echo "old@example.com" > "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  notify_email_set "new@example.com"
  [[ "$(cat "$DEBNAS_NOTIFY_EMAIL_FILE")" == "new@example.com" ]]
  [[ "$(stat -c %a "$DEBNAS_NOTIFY_EMAIL_FILE")" == "640" ]]
  [[ -L "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" ]]
  [[ "$(readlink "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE")" == "$DEBNAS_NOTIFY_EMAIL_FILE" ]]
  run notify_email_get
  [[ "$output" == "new@example.com" ]]
}

@test "notify_email_set: 旧目录不存在时不创建" {
  rm -rf "$T/etc/exim4"
  notify_email_set "new@example.com"
  [[ ! -e "$T/etc/exim4" ]]
}

@test "login_notify_pam_sync: 旧行原位替换为新行" {
  printf 'session [default=1] pam_permit.so\n%s\nsession required pam_unix.so\n' "$OLD_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  run cat "$DEBNAS_PAM_SESSION_FILE"
  [[ "${lines[1]}" == "$NEW_LINE" ]]
  [[ "${#lines[@]}" -eq 3 ]]
  [[ "$output" != *"$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"* ]]
}

@test "login_notify_pam_sync: 新旧两条并存时合并为一条；再次执行返回 1（幂等）" {
  printf '%s\nsession required pam_unix.so\n  %s  \n' "$OLD_LINE" "$NEW_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  [[ "$(grep -c 'login-notify.sh' "$DEBNAS_PAM_SESSION_FILE")" -eq 1 ]]
  run login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  [[ "$status" -eq 1 ]]
  [[ "$(tail -c 1 "$DEBNAS_PAM_SESSION_FILE" | od -An -c | tr -d ' ')" == '\n' ]]
  [[ -n "$(tail -n 1 "$DEBNAS_PAM_SESSION_FILE")" ]]    # 不产生结尾空行
}

@test "login_notify_pam_sync: 无登录通知行时追加；空参数移除全部登录通知行" {
  printf 'session required pam_unix.so\n' > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  [[ "$(tail -n 1 "$DEBNAS_PAM_SESSION_FILE")" == "$NEW_LINE" ]]
  login_notify_pam_sync ""
  [[ "$(cat "$DEBNAS_PAM_SESSION_FILE")" == "session required pam_unix.so" ]]
}

@test "login_notify_pam_sync: 不误伤注释行和其他 pam_exec 行" {
  printf '# %s\nsession optional pam_exec.so /usr/local/bin/other.sh\n' "$OLD_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  run login_notify_pam_sync ""
  [[ "$status" -eq 1 ]]
  grep -q '^# session optional' "$DEBNAS_PAM_SESSION_FILE"
}

@test "login_notify_pam_references: 精确匹配整行" {
  printf '%s\n' "$OLD_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_references "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"
  ! login_notify_pam_references "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
}

# ==================== 审计修复回归（2026-11-10，D1：PAM 行加 seteuid） ====================

@test "login_notify_pam_sync: 生成的行带 seteuid（普通用户 su/pkexec 提权时以 root 运行脚本）" {
  printf 'session required pam_unix.so\n' > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  grep -qxF "session optional pam_exec.so debug seteuid /bin/bash $DEBNAS_LOGIN_NOTIFY_SCRIPT" "$DEBNAS_PAM_SESSION_FILE"
}

@test "login_notify_pam_sync: 不带 seteuid 的旧格式行原位升级，不留两条；再次执行返回 1" {
  printf 'session [default=1] pam_permit.so\n  %s\nsession required pam_unix.so\n' "$NOEUID_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  run login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  [[ "$status" -eq 0 ]]
  run cat "$DEBNAS_PAM_SESSION_FILE"
  [[ "${#lines[@]}" -eq 3 ]]
  [[ "${lines[1]}" == "$NEW_LINE" ]]
  run login_notify_pam_sync "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  [[ "$status" -eq 1 ]]
}

@test "login_notify_pam_sync: 空参数同时移除带与不带 seteuid、新旧路径的全部登录通知行" {
  printf '%s\nsession required pam_unix.so\n%s\n%s\nsession optional pam_exec.so debug seteuid /bin/bash %s\n' \
    "$OLD_LINE" "$NOEUID_LINE" "$NEW_LINE" "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" > "$DEBNAS_PAM_SESSION_FILE"
  run login_notify_pam_sync ""
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$DEBNAS_PAM_SESSION_FILE")" == "session required pam_unix.so" ]]
}

@test "login_notify_pam_references: 带与不带 seteuid 的行都算引用" {
  printf '%s\n' "$NOEUID_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_references "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  printf '%s\n' "$NEW_LINE" > "$DEBNAS_PAM_SESSION_FILE"
  login_notify_pam_references "$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  ! login_notify_pam_references "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"
}
