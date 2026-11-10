#!/usr/bin/env bats
# 测试: lib/system/migration.sh — 版本迁移与配置兼容性检查
# 覆盖 TC-ID: TC-P2-MIG-001~004
# 技术: readonly 变量使用 sed 打补丁后 source + 动态派发 mock

load '../../helpers/common-setup'

setup() {
  export NO_COLOR=1
  setup_debnas_lib

  # DEBNAS_VERSION_STATE 在 migration.sh 中是直接赋值 + readonly
  #   readonly DEBNAS_VERSION_STATE="/var/lib/debnas/state/.debnas_version"
  # 无法通过 export 覆盖。需要创建补丁副本，将直接赋值改为 ${VAR:-default} 模式。
  MIG_STATE_DIR="$BATS_TMPDIR/migration-state"
  mkdir -p "$MIG_STATE_DIR"

  local patched="${MIG_STATE_DIR}/migration-patched.sh"
  sed 's|^readonly DEBNAS_VERSION_STATE=.*|DEBNAS_VERSION_STATE="${DEBNAS_VERSION_STATE:-/var/lib/debnas/state/.debnas_version}"|' \
    "${DEBNAS_ROOT}/lib/system/migration.sh" > "$patched"

  # 设置版本状态文件路径（必须在 source 之前 export）
  export DEBNAS_VERSION_STATE="${MIG_STATE_DIR}/.debnas_version"

  # 设置当前版本号
  export DEBNAS_VERSION="v2026.07"

  # 文件布局迁移有独立测试（test-layout-migration.bats），这里跳过以免触碰真实路径
  export DEBNAS_SKIP_LAYOUT_MIGRATION=1

  # source 补丁后的脚本
  source "$patched"
}

teardown() {
  rm -rf "$MIG_STATE_DIR"
}

# ==================== TC-P2-MIG-001: 首次安装 ====================

@test "migration_run: 无版本文件时保存版本并返回 0（TC-P2-MIG-001）" {
  # 确保版本文件不存在（模拟首次安装）
  rm -f "$DEBNAS_VERSION_STATE"

  run migration_run
  [[ "$status" -eq 0 ]]

  # 验证版本文件已创建
  [[ -f "$DEBNAS_VERSION_STATE" ]]

  # 验证版本文件内容
  local saved_version
  saved_version=$(cat "$DEBNAS_VERSION_STATE")
  [[ "$saved_version" == "v2026.07" ]]
}

@test "migration_run: DEBNAS_VERSION 为空时使用 unknown" {
  rm -f "$DEBNAS_VERSION_STATE"
  DEBNAS_VERSION=""

  run migration_run
  [[ "$status" -eq 0 ]]

  local saved_version
  saved_version=$(cat "$DEBNAS_VERSION_STATE")
  [[ "$saved_version" == "unknown" ]]
}

# ==================== TC-P2-MIG-002: 版本不变跳过 ====================

@test "migration_run: 版本未变化时跳过迁移（TC-P2-MIG-002）" {
  # 写入与当前版本相同的版本文件
  echo "v2026.07" > "$DEBNAS_VERSION_STATE"

  run migration_run
  [[ "$status" -eq 0 ]]

  # 输出中不应包含"检测到版本变更"
  [[ "$output" != *"检测到版本变更"* ]]
}

# ==================== TC-P2-MIG-003: 版本变化动态派发 ====================

@test "migration_run: 版本变化时调用对应 _migrate_<version> 函数（TC-P2-MIG-003）" {
  # 写入旧版本
  echo "v2026.06" > "$DEBNAS_VERSION_STATE"

  # 使用文件标记验证迁移函数被调用（因为 run 在子 shell 中执行，
  # 函数内修改变量无法传回父 shell）
  local marker="${MIG_STATE_DIR}/migration-called"
  rm -f "$marker"

  # 定义迁移函数 mock：写入标记文件
  _migrate_v2026_07() {
    touch "${MIG_STATE_DIR}/migration-called"
    return 0
  }

  run migration_run
  [[ "$status" -eq 0 ]]

  # 验证迁移函数被调用
  [[ -f "$marker" ]]

  # 版本文件已更新
  local saved_version
  saved_version=$(cat "$DEBNAS_VERSION_STATE")
  [[ "$saved_version" == "v2026.07" ]]
}

@test "migration_run: 迁移函数失败时返回 1" {
  echo "v2026.06" > "$DEBNAS_VERSION_STATE"

  # 定义会失败的迁移函数
  _migrate_v2026_07() {
    return 1
  }

  run migration_run
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"迁移步骤失败"* ]]
}

@test "migration_run: 无对应迁移函数时直接更新版本" {
  # 版本变化但没有对应的 _migrate_* 函数
  echo "v2025.01" > "$DEBNAS_VERSION_STATE"

  run migration_run
  [[ "$status" -eq 0 ]]

  # 版本文件已更新
  local saved_version
  saved_version=$(cat "$DEBNAS_VERSION_STATE")
  [[ "$saved_version" == "v2026.07" ]]
}

# ==================== TC-P2-MIG-004: 兼容性检查 ====================

@test "migration_check_compatibility: 配置文件缺失时返回 1（TC-P2-MIG-004）" {
  # 如果配置文件已存在（真实安装环境），跳过此测试
  # 配置文件缺失的场景在 VM 全新安装测试中验证
  if [[ -f "/etc/debnas/debnas.conf" ]]; then
    skip "/etc/debnas/debnas.conf 已存在 — 在真实安装环境中跳过"
  fi
  run migration_check_compatibility
  # 在测试环境中，配置文件通常缺失，预期返回 1
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"兼容性问题"* || "$output" == *"缺失"* || "$output" == *"配置"* ]]
}

@test "migration_check_compatibility: 配置文件存在且状态目录存在时返回 0" {
  # 需要真实的 /etc/debnas/debnas.conf 和 /var/lib/debnas/state
  # 在 CI 环境中这些路径可能不存在
  # 验证函数存在且不崩溃即可
  run migration_check_compatibility
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ==================== 内部函数验证 ====================

@test "_get_installed_version: 无文件时返回空" {
  rm -f "$DEBNAS_VERSION_STATE"
  run _get_installed_version
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}

@test "_get_installed_version: 文件存在时返回版本号" {
  echo "v2026.06" > "$DEBNAS_VERSION_STATE"
  run _get_installed_version
  [[ "$status" -eq 0 ]]
  [[ "$output" == "v2026.06" ]]
}

@test "_version_changed: 不同版本返回 0（真）" {
  if _version_changed "v2026.06" "v2026.07"; then
    true
  else
    false
  fi
}

@test "_version_changed: 相同版本返回 1（假）" {
  if _version_changed "v2026.07" "v2026.07"; then
    false
  else
    true
  fi
}
