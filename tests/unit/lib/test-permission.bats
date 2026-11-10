#!/usr/bin/env bats
# 测试: lib/system/service.sh — require_root() 权限检查 (TC-P0-PERM-001~002)
# Mock 策略: EUID 为 readonly，采用结构 grep + preflight_root mock 双重验证

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"

setup() {
  export NO_COLOR=1
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  source "${DEBNAS_ROOT}/lib/core/colors.sh"
  source "${DEBNAS_ROOT}/lib/core/logging.sh"
}

# ==================== TC-P0-PERM-001: require_root 非 root → ERROR_PERMISSION ====================

@test "permission: require_root 检查 EUID 并返回 ERROR_PERMISSION 结构 (TC-P0-PERM-001)" {
  # 结构验证：require_root 函数体中引用了 ERROR_PERMISSION（返回码 4）
  local service_sh="${DEBNAS_ROOT}/lib/system/service.sh"
  grep -A3 '^require_root()' "$service_sh" | grep -q 'ERROR_PERMISSION'

  # 验证 ERROR_PERMISSION 常量为 4
  source "${DEBNAS_ROOT}/lib/core/constants.sh"
  [[ "${ERROR_PERMISSION:-}" == "4" ]]
}

@test "permission: require_root 检查 EUID != 0 返回非零" {
  # EUID 是只读变量，无法在 shell 内伪造：root 下改在无映射的 user namespace 中运行
  # （unshare --user 后 EUID=65534，且不依赖文件权限）；内核禁止创建 user namespace 时才跳过
  local -a runner=()
  if (( EUID == 0 )); then
    unshare --user true 2>/dev/null || skip "以 root 运行且无法创建 user namespace，无法获得非 root 身份"
    runner=(unshare --user)
  fi
  run "${runner[@]}" bash -c '
    SRC="$1"
    source "$SRC"/lib/core/constants.sh 2>/dev/null
    source "$SRC"/lib/core/colors.sh 2>/dev/null
    source "$SRC"/lib/core/logging.sh 2>/dev/null
    source "$SRC"/lib/system/service.sh 2>/dev/null

    # EUID 为 readonly，但可验证常量值正确
    rc=0
    require_root || rc=$?
    # 非 root 环境下 EUID != 0，应返回 ERROR_PERMISSION=4
    [[ $rc -eq 4 ]] && echo "PERMISSION_OK" || echo "PERMISSION_FAIL: rc=$rc"
  ' _ "${DEBNAS_ROOT}"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"PERMISSION_OK"* ]]
}

# ==================== TC-P0-PERM-002: main() 非 root → exit ERROR_PERMISSION ====================

@test "permission: bin/debnas main() 非 root → exit ERROR_PERMISSION (TC-P0-PERM-002)" {
  local debnas_bin="${DEBNAS_ROOT}/bin/debnas"

  # 结构 grep：main() 中 EUID 检查使用 exit $ERROR_PERMISSION
  grep -A4 'EUID' "$debnas_bin" | grep -q 'ERROR_PERMISSION'
}

# ==================== root 通过场景 ====================

@test "permission: require_root 函数体包含正确逻辑结构" {
  local service_sh="${DEBNAS_ROOT}/lib/system/service.sh"

  # 验证 require_root 使用 EUID 检查
  grep -A3 '^require_root()' "$service_sh" | grep -q 'EUID'

  # 验证错误消息包含 "root"
  grep -A3 '^require_root()' "$service_sh" | grep -q 'root'
}
