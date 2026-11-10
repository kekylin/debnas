#!/usr/bin/env bats
# 测试: lib/system/migration.sh — 文件布局迁移（旧路径 → FHS 同名目录），幂等

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  T="$(mktemp -d "${BATS_TMPDIR}/laymig.XXXXXX")"
  export DEBNAS_ETC_DIR="$T/etc/debnas" DEBNAS_VAR_DIR="$T/var/lib/debnas" DEBNAS_LOG_ROOT="$T/var/log/debnas"
  export DEBNAS_BACKUP_ROOT="$T/var/backups/debnas" DEBNAS_LIBEXEC_DIR="$T/libexec/debnas" DEBNAS_GLOBAL_CONF="$T/none"
  export DEBNAS_LEGACY_NOTIFY_EMAIL_FILE="$T/etc/exim4/notify_email"
  export DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT="$T/etc/pam.d/login-notify.sh" DEBNAS_PAM_SESSION_FILE="$T/etc/pam.d/common-session"
  export DEBNAS_LEGACY_THREAT_IPS_DIR="$T/var/lib/firewalld-ipthreat" DEBNAS_LEGACY_THREAT_IPS_LOG="$T/var/log/firewalld-ipthreat.log"
  unset DEBNAS_BACKUP_RUN_ID DEBNAS_NOTIFY_EMAIL_FILE DEBNAS_LOGIN_NOTIFY_SCRIPT DEBNAS_MANIFEST_FILE DEBNAS_SKIP_LAYOUT_MIGRATION
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/layout.sh"
  source "${DEBNAS_ROOT}/lib/system/manifest.sh"
  source "${DEBNAS_ROOT}/lib/system/backup.sh"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  local patched="$T/migration-patched.sh"
  sed 's|^readonly DEBNAS_VERSION_STATE=.*|DEBNAS_VERSION_STATE="${DEBNAS_VERSION_STATE:-/var/lib/debnas/state/.debnas_version}"|' \
    "${DEBNAS_ROOT}/lib/system/migration.sh" > "$patched"
  export DEBNAS_VERSION_STATE="$T/state/.debnas_version"
  source "$patched"
  crontab() { return 0; }

  mkdir -p "$T/etc/exim4" "$T/etc/pam.d" "$DEBNAS_LEGACY_THREAT_IPS_DIR" "$T/var/log"
  echo "old@example.com" > "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  echo "THREAT_LEVEL=30" > "$DEBNAS_LEGACY_THREAT_IPS_DIR/ipthreat.conf"
  echo "log" > "$DEBNAS_LEGACY_THREAT_IPS_LOG"
  printf '#!/bin/bash\nexit 0\n' > "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"
  printf 'session [default=1] pam_permit.so\nsession optional pam_exec.so debug /bin/bash %s\nsession required pam_unix.so\n' \
    "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" > "$DEBNAS_PAM_SESSION_FILE"
}

teardown() {
  [[ -n "${T:-}" ]] && rm -rf -- "$T"
}

_tree_sum() {
  find "$T" -path "$DEBNAS_BACKUP_ROOT" -prune -o \( -type f -o -type l \) -print0 | sort -z \
    | xargs -0 ls -l --time-style=+ | awk '{print $1, $NF}' | md5sum
}

@test "layout migration: 旧路径全部搬到新路径" {
  migration_run_layout
  [[ "$(cat "$DEBNAS_VAR_DIR/threat-ips/ipthreat.conf")" == "THREAT_LEVEL=30" ]]
  [[ ! -e "$DEBNAS_LEGACY_THREAT_IPS_DIR" ]]
  [[ -f "$DEBNAS_LOG_ROOT/threat-ips.log" && ! -e "$DEBNAS_LEGACY_THREAT_IPS_LOG" ]]
  [[ "$(cat "$DEBNAS_NOTIFY_EMAIL_FILE")" == "old@example.com" ]]
  [[ "$(stat -c %a "$DEBNAS_NOTIFY_EMAIL_FILE")" == "640" ]]
  [[ "$(readlink "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE")" == "$DEBNAS_NOTIFY_EMAIL_FILE" ]]
  [[ -f "$DEBNAS_LOGIN_NOTIFY_SCRIPT" && ! -e "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" ]]
  [[ "$(stat -c %a "$DEBNAS_LOGIN_NOTIFY_SCRIPT")" == "750" ]]
  [[ "$(stat -c %a "$DEBNAS_LIBEXEC_DIR")" == "755" ]]
  [[ "$(grep -c 'login-notify.sh' "$DEBNAS_PAM_SESSION_FILE")" -eq 1 ]]
  grep -qF "/bin/bash $DEBNAS_LOGIN_NOTIFY_SCRIPT" "$DEBNAS_PAM_SESSION_FILE"
}

@test "layout migration: 改动过的旧文件已备份并登记清单（来源 migration）" {
  migration_run_layout
  [[ -f "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$DEBNAS_PAM_SESSION_FILE" ]]
  [[ -f "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" ]]
  grep -q "^$DEBNAS_PAM_SESSION_FILE"$'\t'".*"$'\t'"migration$" "$DEBNAS_MANIFEST_FILE"
}

@test "layout migration: 幂等（第二次运行不改变任何文件）" {
  migration_run_layout
  local before; before=$(_tree_sum)
  migration_run_layout
  [[ "$(_tree_sum)" == "$before" ]]
}

@test "layout migration: 新路径已存在时不覆盖新文件" {
  mkdir -p "$DEBNAS_ETC_DIR" "$DEBNAS_VAR_DIR/threat-ips"
  echo "new@example.com" > "$DEBNAS_NOTIFY_EMAIL_FILE"
  echo "THREAT_LEVEL=80" > "$DEBNAS_VAR_DIR/threat-ips/ipthreat.conf"
  echo "extra" > "$DEBNAS_LEGACY_THREAT_IPS_DIR/extra"
  migration_run_layout
  [[ "$(cat "$DEBNAS_NOTIFY_EMAIL_FILE")" == "new@example.com" ]]
  [[ "$(cat "$DEBNAS_VAR_DIR/threat-ips/ipthreat.conf")" == "THREAT_LEVEL=80" ]]
  [[ -f "$DEBNAS_VAR_DIR/threat-ips/extra" ]]
  [[ -f "$DEBNAS_LEGACY_THREAT_IPS_DIR/ipthreat.conf" ]]     # 冲突文件保留在旧目录，不丢数据
}

@test "layout migration: crontab 仍引用旧威胁 IP 目录时不迁移该目录" {
  crontab() { echo "0 0 * * * $DEBNAS_LEGACY_THREAT_IPS_DIR/firewalld_ipthreat.sh"; }
  run migration_run_layout
  [[ "$status" -eq 0 ]]
  [[ -d "$DEBNAS_LEGACY_THREAT_IPS_DIR" ]]
  [[ "$output" == *"暂不迁移"* ]]
}

@test "layout migration: 失败只告警，migration_run 仍返回 0" {
  chmod 555 "$T/etc/pam.d"
  run migration_run
  chmod 755 "$T/etc/pam.d"
  [[ "$status" -eq 0 ]]
}

@test "layout migration: DEBNAS_SKIP_LAYOUT_MIGRATION=1 跳过" {
  DEBNAS_SKIP_LAYOUT_MIGRATION=1 migration_run_layout
  [[ -f "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" && ! -L "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" ]]
}
