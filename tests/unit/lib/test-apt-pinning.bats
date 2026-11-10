#!/usr/bin/env bats
# 测试: lib/system/apt-pinning.sh — APT Pinning 配置管理
# 覆盖 TC-ID: TC-P2-PIN-001~003
# 技术: 临时目录隔离（APT_PREFERENCES_DIR 覆盖）

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # 覆盖 APT_PREFERENCES_DIR 到临时目录（非 readonly）
  PINNING_DIR="$BATS_TMPDIR/apt-preferences.d"
  mkdir -p "$PINNING_DIR"

  # write_pinning_file 经 write_file_if_changed 写入（utils.sh）
  source "${DEBNAS_ROOT}/lib/system/utils.sh"
  source "${DEBNAS_ROOT}/lib/system/apt-pinning.sh"

  # apt-pinning.sh 中直接赋值 APT_PREFERENCES_DIR="/etc/apt/preferences.d"
  # 覆盖为临时目录（非 readonly，source 后可重新赋值）
  APT_PREFERENCES_DIR="$PINNING_DIR"
}

teardown() {
  rm -rf "$PINNING_DIR"
}

# ==================== TC-P2-PIN-001: write_pinning_file ====================

@test "write_pinning_file: 正确生成 APT preferences 文件（TC-P2-PIN-001）" {
  local pinning_file="${PINNING_DIR}/test-backports.pref"
  local os_codename="bookworm"

  run write_pinning_file "$pinning_file" "$os_codename" "cockpit" "cockpit-*"
  [[ "$status" -eq 0 ]]

  # 文件已创建
  [[ -f "$pinning_file" ]]

  # 权限为 644
  local perm
  perm=$(stat -c '%a' "$pinning_file")
  [[ "$perm" == "644" ]]

  # 文件内容包含 Package/Pin/Pin-Priority 块
  local content
  content=$(cat "$pinning_file")
  [[ "$content" == *"Package: cockpit"* ]]
  [[ "$content" == *"Package: cockpit-*"* ]]
  [[ "$content" == *"Pin: release n=${os_codename}-backports"* ]]
  [[ "$content" == *"Pin-Priority: 500"* ]]
  [[ "$content" == *"系统版本: ${os_codename}"* ]]
  [[ "$content" == *"优先从 backports 安装/更新"* ]]
}

@test "write_pinning_file: 多个包组的 Pin 块各自独立" {
  local pinning_file="${PINNING_DIR}/multi.pref"

  write_pinning_file "$pinning_file" "bookworm" "nginx" "php" "mariadb"

  local content
  content=$(cat "$pinning_file")

  # 每个包组有独立的三行块
  local nginx_block php_block mariadb_block
  nginx_block=$(grep -A2 "Package: nginx" "$pinning_file" || true)
  php_block=$(grep -A2 "Package: php" "$pinning_file" || true)
  mariadb_block=$(grep -A2 "Package: mariadb" "$pinning_file" || true)

  [[ -n "$nginx_block" ]]
  [[ -n "$php_block" ]]
  [[ -n "$mariadb_block" ]]
}

@test "write_pinning_file: 自动创建 preferences.d 目录" {
  # 使用全新的临时目录（不预先创建）
  local clean_dir="${BATS_TMPDIR}/apt-new-$(date +%s)"
  APT_PREFERENCES_DIR="$clean_dir"

  # write_pinning_file 内部有 mkdir -p，应自动创建目录
  run write_pinning_file "${clean_dir}/auto.pref" "bookworm" "testpkg"
  [[ "$status" -eq 0 ]]
  [[ -d "$clean_dir" ]]
  [[ -f "${clean_dir}/auto.pref" ]]

  rm -rf "$clean_dir"

  # 恢复 APT_PREFERENCES_DIR（避免影响后续测试）
  APT_PREFERENCES_DIR="$PINNING_DIR"
}

# ==================== TC-P2-PIN-002: check_pinning_status ====================

@test "check_pinning_status: 文件存在时返回 0（TC-P2-PIN-002）" {
  local pinning_file="${PINNING_DIR}/exists.pref"
  touch "$pinning_file"

  run check_pinning_status "$pinning_file"
  [[ "$status" -eq 0 ]]
}

@test "check_pinning_status: 文件不存在时返回 1" {
  run check_pinning_status "${PINNING_DIR}/absent.pref"
  [[ "$status" -ne 0 ]]
}

# ==================== TC-P2-PIN-003: cleanup_pinning_config ====================

@test "cleanup_pinning_config: 删除存在的文件返回 0（TC-P2-PIN-003）" {
  local pinning_file="${PINNING_DIR}/to-clean.pref"
  echo "# test config" > "$pinning_file"

  run cleanup_pinning_config "$pinning_file"
  [[ "$status" -eq 0 ]]
  [[ ! -f "$pinning_file" ]]
}

@test "cleanup_pinning_config: 文件不存在时仍返回 0（幂等性）" {
  run cleanup_pinning_config "${PINNING_DIR}/already-gone.pref"
  [[ "$status" -eq 0 ]]
}

# ==================== configure_* 委托函数 ====================

@test "configure_cockpit_pinning: 生成正确的 cockpit pinning 文件" {
  run configure_cockpit_pinning "bookworm"
  [[ "$status" -eq 0 ]]

  local pinning_file="${PINNING_DIR}/cockpit-backports.pref"
  [[ -f "$pinning_file" ]]

  local content
  content=$(cat "$pinning_file")
  [[ "$content" == *"Package: cockpit"* ]]
  [[ "$content" == *"Package: cockpit-*"* ]]
  [[ "$content" == *"Package: pcp"* ]]
  [[ "$content" == *"Package: python3-pcp"* ]]
  [[ "$content" == *"Package: tuned"* ]]
}

@test "configure_component_pinning: 生成组件级别的 pinning 文件" {
  run configure_component_pinning "bookworm" "nginx" "nginx nginx-*"
  [[ "$status" -eq 0 ]]

  local pinning_file="${PINNING_DIR}/nginx-backports.pref"
  [[ -f "$pinning_file" ]]

  local content
  content=$(cat "$pinning_file")
  [[ "$content" == *"Package: nginx nginx-*"* ]]
}

# ==================== 幂等与只读判断 ====================

@test "write_pinning_file: 内容不含时间戳，重复写入不改动文件" {
  local pinning_file="${PINNING_DIR}/idem.pref"
  write_pinning_file "$pinning_file" "bookworm" "cockpit"
  [[ "$(cat "$pinning_file")" != *"配置时间"* ]]
  local before
  before=$(stat -c '%i %Y' "$pinning_file")
  sleep 1
  run write_pinning_file "$pinning_file" "bookworm" "cockpit"
  [[ "$status" -eq 0 ]]
  [[ "$(stat -c '%i %Y' "$pinning_file")" == "$before" ]]
}

@test "write_pinning_file: 内容变化时原子替换并保持 644" {
  local pinning_file="${PINNING_DIR}/change.pref"
  write_pinning_file "$pinning_file" "bookworm" "cockpit"
  run write_pinning_file "$pinning_file" "trixie" "cockpit"
  [[ "$status" -eq 0 ]]
  grep -q 'n=trixie-backports' "$pinning_file"
  [[ "$(stat -c '%a' "$pinning_file")" == "644" ]]
  [[ -z "$(find "$PINNING_DIR" -name '.*.debnas.*')" ]]
}

@test "pinning_render: 与写入内容一致（供 module_plan 比较）" {
  local pinning_file="${PINNING_DIR}/render.pref"
  write_pinning_file "$pinning_file" "bookworm" "a" "b-*"
  [[ "$(cat "$pinning_file")" == "$(pinning_render bookworm a 'b-*')" ]]
}

@test "pinning_file_exists: 只读判断不输出日志" {
  touch "${PINNING_DIR}/x.pref"
  run pinning_file_exists "${PINNING_DIR}/x.pref"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
  run pinning_file_exists "${PINNING_DIR}/none.pref"
  [[ "$status" -eq 1 ]]
  [[ -z "$output" ]]
}
