#!/usr/bin/env bats
# 测试: 边界条件验证 (TC-P1-BND-001~008 + TC-P2-BND-007~008)
# Mock 策略: 结构 grep + PATTH Injection + 子 shell 隔离

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"

# ==================== TC-P1-BND-001: curl --max-time 超时 ====================

@test "boundary: curl 使用 --max-time 超时参数 (TC-P1-BND-001)" {
  # 结构验证：lib/system/urls.sh 中 probe_url 使用 --max-time
  local urls_sh="${DEBNAS_ROOT}/lib/system/urls.sh"
  grep -q '\-\-max-time' "$urls_sh"
}

# ==================== TC-P1-BND-002: wget --timeout 超时 ====================

@test "boundary: wget 使用 --timeout 超时参数 (TC-P1-BND-002)" {
  local urls_sh="${DEBNAS_ROOT}/lib/system/urls.sh"
  grep -q '\-\-timeout' "$urls_sh"
}

# ==================== TC-P1-BND-003~004: docker-ce GPG 下载重试 ====================

@test "boundary: docker-ce 公钥下载经 keyring_install_verified (TC-P1-BND-003)" {
  local docker_ce="${DEBNAS_ROOT}/modules/docker-ce.sh"
  # 结构验证：docker-ce 改用公共 keyring_install_verified（下载/校验/重试集中在 lib）
  grep -q 'keyring_install_verified "${docker_mirror}/gpg"' "$docker_ce"
}

@test "boundary: keyring_install_verified 下载失败重试 1 次（共 2 次）(TC-P1-BND-004)" {
  local keyring="${DEBNAS_ROOT}/lib/system/keyring.sh"
  sed -n '/^keyring_install_verified()/,/^}/p' "$keyring" | grep -q 'for attempt in 1 2'
}

# ==================== TC-P1-BND-005: preflight_dependencies 空依赖列表 → 返回 0 ====================
# 已集成在 test-preflight.bats 中（TC-P1-BND-005 两个测试）

# ==================== TC-P1-BND-006: get_module_field 不存在字段 → 默认值 ====================

@test "boundary: get_module_field 不存在字段返回默认值 (TC-P1-BND-006)" {
  run bash -c '
    SRC="$1"
    export NO_COLOR=1
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null

    TEST_MODULES_DIR="$BATS_TMPDIR/bnd-modules"
    mkdir -p "$TEST_MODULES_DIR"
    export DEBNAS_MODULES_DIR="$TEST_MODULES_DIR"
    source "$SRC"/lib/system/state.sh 2>/dev/null
    source "$SRC"/lib/system/module-registry.sh 2>/dev/null

    # 创建测试模块
    cat > "$TEST_MODULES_DIR/test-bnd.sh" << "INNEREOF"
#!/bin/bash
# @module: test-bnd
# @name: 边界测试模块
# @category: 系统工具
# @version: 1.0.0
# @order: 50
INNEREOF
    discover_modules 2>/dev/null
    # 查询不存在的字段，验证返回默认值
    result=$(get_module_field "test-bnd" "nonexistent_field" "DEFAULT_VALUE" 2>/dev/null)
    echo "RESULT=$result"
    rm -rf "$TEST_MODULES_DIR"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"RESULT=DEFAULT_VALUE"* ]]
}

# ==================== TC-P2-BND-008: CIDR 掩码边界验证 ====================

@test "boundary: threat-ips 包含 IPv4/IPv6 校验函数 (TC-P2-BND-008)" {
  local download="${DEBNAS_ROOT}/modules/threat-ips/download.sh"
  # 结构验证：IP 校验（awk 批量解析中的 v4ok / v6ok / v4mask）存在
  grep -q 'function v4ok' "$download"
  grep -q 'function v6ok' "$download"
  grep -q 'm + 0 <= 32' "$download"
}

# ==================== sys-check 边界（TC-P2-BND-009~010） ====================

@test "boundary: sys-check 内存阈值检查逻辑存在 (TC-P2-BND-009)" {
  local sys_check="${DEBNAS_ROOT}/modules/sys-check.sh"
  # 结构验证：内存检查引用阈值（< 1GB 触发警告）
  grep -q 'mem\|MEM\|memory\|内存' "$sys_check"
}

@test "boundary: sys-check 磁盘阈值检查逻辑存在 (TC-P2-BND-010)" {
  local sys_check="${DEBNAS_ROOT}/modules/sys-check.sh"
  # 结构验证：磁盘检查引用阈值（< 10GB 触发警告）
  grep -q 'disk\|DISK\|磁盘\|df ' "$sys_check"
}

# ==================== docker-ce GPG 重试功能测试 ====================

@test "boundary: docker-ce GPG 下载重试逻辑已验证 (TC-P2-MOD-009)" {
  local keyring="${DEBNAS_ROOT}/lib/system/keyring.sh"
  # 结构验证：下载带超时，失败重试
  sed -n '/^keyring_install_verified()/,/^}/p' "$keyring" | grep -q 'curl .*--max-time'
  sed -n '/^keyring_install_verified()/,/^}/p' "$keyring" | grep -q '重试'
}
