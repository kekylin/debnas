#!/usr/bin/env bats
# 测试: lib/system/backup.sh — 集中备份与保留策略（普通用户 + 目录常量覆盖到临时目录）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  T="$(mktemp -d "${BATS_TMPDIR}/backup.XXXXXX")"
  export DEBNAS_ETC_DIR="$T/etc/debnas" DEBNAS_VAR_DIR="$T/var/lib/debnas" DEBNAS_LOG_ROOT="$T/var/log/debnas"
  export DEBNAS_BACKUP_ROOT="$T/var/backups/debnas" DEBNAS_LIBEXEC_DIR="$T/libexec/debnas"
  export DEBNAS_GLOBAL_CONF="$T/etc/debnas/debnas.conf"
  unset DEBNAS_BACKUP_RUN_ID DEBNAS_BACKUP_ENABLED DEBNAS_BACKUP_KEEP
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/layout.sh"
  source "${DEBNAS_ROOT}/lib/system/manifest.sh"
  source "${DEBNAS_ROOT}/lib/system/backup.sh"
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  mkdir -p "$T/sys"
}

teardown() {
  [[ -n "${T:-}" ]] && rm -rf -- "$T"
}

@test "backup: 运行 ID 格式为 YYYYmmdd-HHMMSS-pid 且已 export" {
  [[ "$DEBNAS_BACKUP_RUN_ID" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]
  run bash -c 'echo "$DEBNAS_BACKUP_RUN_ID"'
  [[ "$output" == "$DEBNAS_BACKUP_RUN_ID" ]]
}

@test "backup: 修改已有文件前备份到 <运行目录>/<原绝对路径>，保留权限，目录 700" {
  printf 'old\n' > "$T/sys/a.conf"; chmod 604 "$T/sys/a.conf"
  write_file_if_changed "$T/sys/a.conf" "new"
  local b="$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$T/sys/a.conf"
  [[ "$(cat "$b")" == "old" ]]
  [[ "$(stat -c %a "$b")" == "604" ]]
  [[ "$(stat -c %a "$DEBNAS_BACKUP_ROOT")" == "700" ]]
  [[ "$(stat -c %a "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID")" == "700" ]]
  [[ "$(cat "$DEBNAS_BACKUP_ROOT/original$T/sys/a.conf")" == "old" ]]
  [[ "$(cat "$T/sys/a.conf")" == "new" ]]
}

@test "backup: 同一次运行多次修改只保留第一次（运行前）的版本" {
  printf 'v1\n' > "$T/sys/a.conf"
  write_file_if_changed "$T/sys/a.conf" "v2"
  write_file_if_changed "$T/sys/a.conf" "v3"
  [[ "$(cat "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$T/sys/a.conf")" == "v1" ]]
}

@test "backup: 内容未变化或新建文件时不备份" {
  write_file_if_changed "$T/sys/new.conf" "x"
  run write_file_if_changed "$T/sys/new.conf" "x"
  [[ "$status" -eq 1 ]]
  [[ ! -e "$DEBNAS_BACKUP_ROOT" ]]
}

@test "backup: DEBNAS_BACKUP_ENABLED=0 / backup_enabled=0 关闭备份，写入照常" {
  printf 'old\n' > "$T/sys/a.conf"
  DEBNAS_BACKUP_ENABLED=0 write_file_if_changed "$T/sys/a.conf" "new"
  [[ ! -e "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID" ]]
  mkdir -p "$DEBNAS_ETC_DIR"; echo "backup_enabled=0" > "$DEBNAS_GLOBAL_CONF"
  write_file_if_changed "$T/sys/a.conf" "newer"
  [[ ! -e "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID" ]]
  [[ "$(cat "$T/sys/a.conf")" == "newer" ]]
}

@test "backup: 备份失败只告警，仍然写入" {
  printf 'old\n' > "$T/sys/a.conf"
  mkdir -p "$(dirname "$DEBNAS_BACKUP_ROOT")"; : > "$DEBNAS_BACKUP_ROOT"   # 备份根被普通文件占位 → 备份失败
  run write_file_if_changed "$T/sys/a.conf" "new"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"备份原文件失败"* ]]
  [[ "$(cat "$T/sys/a.conf")" == "new" ]]
}

@test "backup: 符号链接目标备份真实文件，链接保持不变" {
  printf 'real\n' > "$T/sys/real.conf"; ln -s real.conf "$T/sys/link.conf"
  write_file_if_changed "$T/sys/link.conf" "via"
  [[ -L "$T/sys/link.conf" ]]
  [[ "$(cat "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$T/sys/real.conf")" == "real" ]]
}

@test "backup: debnas_backup_file 返回码 0 已备份 / 2 文件不存在" {
  printf 'x\n' > "$T/sys/a.conf"
  run debnas_backup_file "$T/sys/a.conf"
  [[ "$status" -eq 0 ]]
  run debnas_backup_file "$T/sys/missing.conf"
  [[ "$status" -eq 2 ]]
}

@test "backup: 子进程继承运行 ID，共用一个运行目录" {
  printf 'x\n' > "$T/sys/a.conf"; printf 'y\n' > "$T/sys/b.conf"
  debnas_backup_file "$T/sys/a.conf"
  bash -c 'source "$1/lib/core/logging.sh"; source "$1/lib/system/layout.sh"; source "$1/lib/system/manifest.sh"; source "$1/lib/system/backup.sh"; debnas_backup_file "$2"' _ "$DEBNAS_ROOT" "$T/sys/b.conf"
  [[ -f "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID$T/sys/b.conf" ]]
  [[ "$(find "$DEBNAS_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]]   # 运行目录 + original
}

@test "backup: 保留策略只删除超出部分，跳过非运行目录/符号链接/当前运行" {
  mkdir -p "$DEBNAS_BACKUP_ROOT"
  local i
  for i in $(seq 1 25); do mkdir "$DEBNAS_BACKUP_ROOT/20200101-0000$(printf %02d "$i")-$((100 + i))"; done
  mkdir "$DEBNAS_BACKUP_ROOT/original" "$DEBNAS_BACKUP_ROOT/not-a-run" "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID"
  mkdir "$T/outside"; ln -s "$T/outside" "$DEBNAS_BACKUP_ROOT/20190101-000000-1"
  DEBNAS_BACKUP_KEEP=5 debnas_backup_prune
  run bash -c 'ls "$1" | grep -E "^[0-9]{8}-[0-9]{6}-[0-9]+$" | grep -v "^2019"' _ "$DEBNAS_BACKUP_ROOT"
  [[ "${#lines[@]}" -eq 5 ]]
  [[ "${lines[0]}" == "20200101-000022-122" ]]
  [[ -d "$DEBNAS_BACKUP_ROOT/$DEBNAS_BACKUP_RUN_ID" ]]
  [[ -d "$DEBNAS_BACKUP_ROOT/original" && -d "$DEBNAS_BACKUP_ROOT/not-a-run" ]]
  [[ -L "$DEBNAS_BACKUP_ROOT/20190101-000000-1" && -d "$T/outside" ]]
}

@test "backup: 同一秒内 pid 按数值排序" {
  mkdir -p "$DEBNAS_BACKUP_ROOT/20200101-000000-999" "$DEBNAS_BACKUP_ROOT/20200101-000000-1000"
  DEBNAS_BACKUP_RUN_ID="20300101-000000-1" debnas_backup_prune 1
  [[ ! -d "$DEBNAS_BACKUP_ROOT/20200101-000000-999" ]]
  [[ -d "$DEBNAS_BACKUP_ROOT/20200101-000000-1000" ]]
}

@test "backup: 备份根目录为 / 或相对路径时拒绝清理" {
  DEBNAS_BACKUP_ROOT="/" run debnas_backup_prune
  [[ "$status" -eq 1 ]]
  DEBNAS_BACKUP_ROOT="relative/dir" run debnas_backup_prune
  [[ "$status" -eq 1 ]]
}
