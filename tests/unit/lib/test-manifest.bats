#!/usr/bin/env bats
# 测试: lib/system/manifest.sh — 文件清单登记与分组输出

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  T="$(mktemp -d "${BATS_TMPDIR}/manifest.XXXXXX")"
  export DEBNAS_ETC_DIR="$T/etc/debnas" DEBNAS_VAR_DIR="$T/var/lib/debnas" DEBNAS_LOG_ROOT="$T/var/log/debnas"
  export DEBNAS_BACKUP_ROOT="$T/var/backups/debnas" DEBNAS_LIBEXEC_DIR="$T/libexec/debnas"
  export DEBNAS_MANIFEST_FILE="$T/var/lib/debnas/manifest" DEBNAS_GLOBAL_CONF="$T/none"
  unset DEBNAS_BACKUP_RUN_ID DEBNAS_MANIFEST_SOURCE
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/layout.sh"
  source "${DEBNAS_ROOT}/lib/system/manifest.sh"
  source "${DEBNAS_ROOT}/lib/system/backup.sh"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  mkdir -p "$T/sys"
  crontab() { printf '0 0 * * * DEBNAS_CRON_MODE=1 /usr/local/bin/debnas run hosts-sync # DEBNAS-CRON: hosts-sync\n5 5 * * * other\n'; }
}

teardown() {
  [[ -n "${T:-}" ]] && rm -rf -- "$T"
}

@test "manifest: 同一路径只登记一次（保留首次时间与来源）" {
  DEBNAS_MANIFEST_SOURCE=mod-a manifest_add "$T/sys/a.conf"
  DEBNAS_MANIFEST_SOURCE=mod-b manifest_add "$T/sys/a.conf"
  [[ "$(wc -l < "$DEBNAS_MANIFEST_FILE")" -eq 1 ]]
  [[ "$(cut -f3 "$DEBNAS_MANIFEST_FILE")" == "mod-a" ]]
  [[ "$(stat -c %a "$DEBNAS_MANIFEST_FILE")" == "640" ]]
}

@test "manifest: write_file_if_changed 写入系统文件时自动登记，自有目录不登记" {
  write_file_if_changed "$T/sys/a.conf" "x"
  write_file_if_changed "$T/sys/a.conf" "y"
  write_file_if_changed "$DEBNAS_ETC_DIR/x.conf" "z"
  [[ "$(wc -l < "$DEBNAS_MANIFEST_FILE")" -eq 1 ]]
  grep -q "^$T/sys/a.conf"$'\t' "$DEBNAS_MANIFEST_FILE"
}

@test "manifest: 拒绝相对路径与含换行/制表符的路径" {
  manifest_add "relative/path"
  manifest_add "$T/sys/bad"$'\n'"x"
  [[ ! -e "$DEBNAS_MANIFEST_FILE" ]]
}

@test "manifest: 来源模块从入口脚本路径推断" {
  run bash -c 'source "$1/lib/system/manifest.sh"; _manifest_source' /opt/debnas/modules/threat-ips/module.sh "$DEBNAS_ROOT"
  [[ "$output" == "threat-ips" ]]
  run bash -c 'source "$1/lib/system/manifest.sh"; _manifest_source' /opt/debnas/modules/sources.sh "$DEBNAS_ROOT"
  [[ "$output" == "sources" ]]
}

@test "manifest_list: 输出四个分组，标注存在性与备份份数" {
  printf 'old\n' > "$T/sys/a.conf"
  write_file_if_changed "$T/sys/a.conf" "new"
  manifest_add "$T/sys/gone.conf"
  run manifest_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"== DebNAS 自有目录 =="* ]]
  [[ "$output" == *"== 修改过的系统文件"* ]]
  [[ "$output" == *"== 定时任务"* ]]
  [[ "$output" == *"== 审计目录（原地保留） =="* ]]
  [[ "$output" == *"/var/log/history"* ]]
  echo "$output" | grep -F "$T/sys/a.conf" | grep -q "备份 2 份"     # 运行目录 + original
  echo "$output" | grep -F "$T/sys/gone.conf" | grep -q "已不存在"
  echo "$output" | grep -q "DEBNAS-CRON: hosts-sync"
  ! echo "$output" | grep -q "other"
}

@test "manifest_list: 清单为空时给出提示" {
  run manifest_list
  [[ "$output" == *"暂无记录"* ]]
}
