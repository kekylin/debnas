#!/usr/bin/env bats
# 测试: lib/system/config.sh — 配置读写

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/config.sh"
  TEST_CONF_DIR=$(mktemp -d)
  eval "DEBNAS_CONF_DIR=$TEST_CONF_DIR"
  eval "DEBNAS_GLOBAL_CONF=${TEST_CONF_DIR}/debnas.conf"
}

teardown() {
  rm -rf "$TEST_CONF_DIR"
}

@test "config_write 创建配置文件" {
  config_write "test" "key1" "value1"
  [ -f "${TEST_CONF_DIR}/test.conf" ]
}

@test "config_read 读取已写入的值" {
  config_write "test" "region" "cn"
  result=$(config_read "test" "region")
  [ "$result" = "cn" ]
}

@test "config_read 不存在的键返回默认值" {
  result=$(config_read "test" "missing" "default_val")
  [ "$result" = "default_val" ]
}

@test "config_read 不存在的文件返回默认值" {
  result=$(config_read "nonexistent" "key" "fallback")
  [ "$result" = "fallback" ]
}

@test "config_write 更新已有值" {
  config_write "test" "lang" "zh"
  config_write "test" "lang" "en"
  result=$(config_read "test" "lang")
  [ "$result" = "en" ]
}

@test "config_delete 删除键" {
  config_write "test" "key1" "val1"
  config_delete "test" "key1"
  run config_read "test" "key1"
  [ "$status" -ne 0 ]
}

@test "config_write 敏感文件权限 600" {
  config_write "mail" "password" "secret123" "600"
  perm=$(stat -c '%a' "${TEST_CONF_DIR}/mail.conf")
  [ "$perm" = "600" ]
}


@test "config_write: 写入 .tmp 失败时保护原文件内容（TC-P2-ATOM-001）" {
  # 先写入初始值
  config_write "atom" "key" "original_value"

  local conf_file="${DEBNAS_CONF_DIR}/atom.conf"

  # 验证初始值正确
  local before
  before=$(config_read "atom" "key")
  [[ "$before" == "original_value" ]]

  # 失败注入：.tmp 路径被同名目录占用，重定向写入必然失败（不依赖文件权限，root 下同样生效；
  # 旧做法 chmod -w 目录对 root 无效）
  mkdir "${conf_file}.tmp"

  # 尝试更新（应因无法写入 .tmp 而失败）
  run config_write "atom" "key" "new_value"
  [[ "$status" -ne 0 ]]
  rmdir "${conf_file}.tmp"

  # 验证原文件内容未被破坏
  local after
  after=$(cat "$conf_file" 2>/dev/null || true)
  [[ "$after" == *"original_value"* ]]
  [[ "$after" != *"new_value"* ]]
}

# ==================== TC-P2-ATOM-002: mv 失败保护原文件 ====================

@test "config_write: mv 失败时保护原文件内容（TC-P2-ATOM-002）" {
  # 先写入初始值
  config_write "atom2" "key" "original_value"

  local conf_file="${DEBNAS_CONF_DIR}/atom2.conf"
  [[ -f "$conf_file" ]]

  # 验证初始值
  local before
  before=$(config_read "atom2" "key")
  [[ "$before" == "original_value" ]]

  # 覆盖 mv 命令模拟权限不足
  mv() { return 1; }

  # 尝试更新已有键（触发 awk 替换 + mv 路径）
  run config_write "atom2" "key" "new_value"
  # config_write 在 mv 失败时返回非 0（取决于实现是否检查 mv 返回值）
  # 关键断言：原文件内容未丢失
  local after
  after=$(cat "$conf_file" 2>/dev/null || true)
  [[ "$after" == *"original_value"* ]]
}

@test "config_write: mv 失败后 .tmp 残留情况记录" {
  # 先写入初始值
  config_write "atom3" "key" "original_value"

  local tmp_file="${DEBNAS_CONF_DIR}/atom3.conf.tmp"

  # 覆盖 mv 命令模拟失败
  mv() { return 1; }

  run config_write "atom3" "key" "new_value"

  # 验证原文件内容仍在
  result=$(config_read "atom3" "key")
  [[ "$result" == "original_value" ]]

  # 记录当前行为：mv 失败时 .tmp 是否残留
  # （这是当前实现的已知行为记录，不是必须通过的断言）
  echo "note: .tmp exists = $([ -f "$tmp_file" ] && echo yes || echo no)" >&2
}

# ==================== config_get_bool ====================

@test "config_get_bool: 未设置时按默认值" {
  run config_get_bool "add_user_to_sudo" "1"
  [ "$status" -eq 0 ]
  run config_get_bool "cockpit_behind_proxy" "0"
  [ "$status" -eq 1 ]
}

@test "config_get_bool: 识别 1/0、true/false、yes/no、on/off（不分大小写）" {
  local v
  for v in 1 true YES On; do
    config_write "global" "flag_a" "$v"
    run config_get_bool "flag_a" "0"
    [ "$status" -eq 0 ]
  done
  for v in 0 false No OFF; do
    config_write "global" "flag_a" "$v"
    run config_get_bool "flag_a" "1"
    [ "$status" -eq 1 ]
  done
}

@test "config_get_bool: 无法识别的值按默认值；默认为空时返回 2（三态）" {
  config_write "global" "flag_b" "maybe"
  run config_get_bool "flag_b" "1"
  [ "$status" -eq 0 ]
  run config_get_bool "flag_b" ""
  [ "$status" -eq 2 ]
  run config_get_bool "file_sharing_nfs" ""
  [ "$status" -eq 2 ]
}

@test "config_get_bool: 不输出任何内容" {
  config_write "global" "flag_c" "1"
  run config_get_bool "flag_c" "0"
  [ -z "$output" ]
}

# ==================== config_get_url ====================

@test "config_get_url: 留空用默认地址并去掉末尾 /" {
  log_error() { echo "ERR:$*" >&2; }
  run config_get_url "repo_x_url" "https://repo.example.com/debian/"
  [ "$status" -eq 0 ]
  [ "$output" = "https://repo.example.com/debian" ]
}

@test "config_get_url: 配置的镜像地址优先；非 http(s) / 含空白 → 失败" {
  log_error() { echo "ERR:$*" >&2; }
  config_write "global" "repo_x_url" "http://mirror.example.cn/x"
  run config_get_url "repo_x_url" "https://repo.example.com"
  [ "$output" = "http://mirror.example.cn/x" ]
  config_write "global" "repo_x_url" "ftp://mirror.example.cn/x"
  run config_get_url "repo_x_url" "https://repo.example.com"
  [ "$status" -eq 1 ]
  config_write "global" "repo_x_url" "https://a.example.com https://b.example.com"
  run config_get_url "repo_x_url" "https://repo.example.com"
  [ "$status" -eq 1 ]
}

@test "config_write: 并发改写不同键持锁，不丢更新" {
  export DEBNAS_TMP_BASE="$BATS_TMPDIR/config-lock-base"
  rm -rf "$DEBNAS_TMP_BASE"
  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  local i
  for i in 1 2 3 4 5 6; do config_write "test" "k$i" "old"; done
  # 读改写之间留出时间窗：不加锁时并发替换会互相覆盖（共用 .tmp 且基于旧内容）
  awk() { command awk "$@"; local rc=$?; sleep 0.2; return $rc; }
  for i in 1 2 3 4 5 6; do config_write "test" "k$i" "new$i" & done
  wait
  unset -f awk
  for i in 1 2 3 4 5 6; do
    [ "$(config_read "test" "k$i")" = "new$i" ]
  done
}
